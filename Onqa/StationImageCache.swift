import Foundation
import ImageIO
import UIKit

/// Downloads a logo with a hard size cap. The cap is enforced while bytes
/// arrive, so chunked responses without a Content-Length cannot exceed it.
/// Task cancellation stops the transfer. URLCache stays shared across sessions.
enum BoundedLogoDownload {
    static func load(
        from url: URL,
        maximumBytes: Int,
        cache: URLCache
    ) async throws -> Data {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = cache
        configuration.requestCachePolicy = .useProtocolCachePolicy
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        let (bytes, response) = try await session.bytes(from: url)
        if let http = response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        if response.expectedContentLength > Int64(maximumBytes) {
            throw URLError(.dataLengthExceedsMaximum)
        }

        var data = Data()
        for try await byte in bytes {
            guard data.count < maximumBytes else {
                throw URLError(.dataLengthExceedsMaximum)
            }
            data.append(byte)
        }
        guard !data.isEmpty else { throw URLError(.zeroByteResource) }
        return data
    }
}

/// Shared artwork cache. URLCache owns HTTP-aware memory/disk caching and eviction;
/// decoded bitmaps stay in an NSCache so list rows and Now Playing reuse rasterized art.
actor StationImageCache {
    static let shared = StationImageCache()

    private static let maximumLogoBytes = 8 * 1024 * 1024


    private static let urlCache = URLCache(
        memoryCapacity: 32 * 1024 * 1024,
        diskCapacity: 64 * 1024 * 1024,
        diskPath: "StationLogos"
    )
    private let decoded = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<Data, Error>] = [:]
    private var svgRenderTasks: [String: Task<UIImage?, Never>] = [:]
    private var activeSVGRenderCount = 0
    private var svgRenderWaiters: [CheckedContinuation<Void, Never>] = []

    private init() {
        decoded.countLimit = 160
        decoded.totalCostLimit = 48 * 1024 * 1024
    }

    /// URLCache handles cache validation, persistence, and eviction using the
    /// response's HTTP cache headers. The in-flight table coalesces simultaneous
    /// requests for the same logo before URLCache has a response to reuse.
    func data(for url: URL) async throws -> Data {
        let key = url.absoluteString
        if let existing = inFlight[key] {
            return try await existing.value
        }

        let request = Task<Data, Error> {
            // The delegate enforces the cap while chunks arrive, including
            // chunked/unknown-length responses that have no Content-Length.
            let data = try await BoundedLogoDownload.load(
                from: Self.secureURL(url),
                maximumBytes: Self.maximumLogoBytes,
                cache: Self.urlCache
            )
            guard Self.isUsableLogo(data) else {
                throw URLError(.cannotDecodeContentData)
            }
            return data
        }
        inFlight[key] = request

        do {
            let downloaded = try await request.value
            inFlight[key] = nil
            return downloaded
        } catch {
            inFlight[key] = nil
            throw error
        }
    }

    /// App Transport Security only exempts audio/video loads, not logos, so an
    /// `http://` logo URL would always fail. Try HTTPS instead; a server that
    /// does not offer it fails as before and the station keeps its placeholder.
    /// URLs with an explicit port are left alone, as that port is unlikely to
    /// speak TLS.
    static func secureURL(_ url: URL) -> URL {
        guard url.scheme?.lowercased() == "http",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.port == nil else { return url }
        components.scheme = "https"
        return components.url ?? url
    }

    /// Decoded, downsampled raster logo. The ImageIO thumbnail avoids decoding
    /// full-size bitmap assets into list rows.
    func thumbnail(for url: URL, data: Data, maxPixel: CGFloat) -> UIImage? {
        let pixels = max(1, Int(maxPixel.rounded(.up)))
        let key = "\(url.absoluteString)@\(pixels)" as NSString
        if let cached = decoded.object(forKey: key) { return cached }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }

        let image = UIImage(cgImage: cgImage)
        decoded.setObject(image, forKey: key, cost: cgImage.bytesPerRow * cgImage.height)
        return image
    }

    /// Rasterizes an SVG once per URL and caches the resulting bitmap alongside
    /// ordinary decoded thumbnails. At most two WebKit renders run concurrently.
    func renderedSVG(for url: URL, data: Data) async -> UIImage? {
        let cacheKey = "\(url.absoluteString)@svg"
        let key = cacheKey as NSString
        if let cached = decoded.object(forKey: key) { return cached }
        if let existing = svgRenderTasks[cacheKey] {
            return await existing.value
        }

        await acquireSVGRenderSlot()
        guard !Task.isCancelled else {
            releaseSVGRenderSlot()
            return nil
        }

        if let cached = decoded.object(forKey: key) {
            releaseSVGRenderSlot()
            return cached
        }
        if let existing = svgRenderTasks[cacheKey] {
            releaseSVGRenderSlot()
            return await existing.value
        }

        let renderTask = Task<UIImage?, Never> {
            await SVGNowPlayingArtworkRenderer.render(data: data)
        }
        svgRenderTasks[cacheKey] = renderTask
        let image = await renderTask.value
        svgRenderTasks[cacheKey] = nil

        if let image {
            let cost = image.cgImage.map { $0.bytesPerRow * $0.height }
                ?? Int(image.size.width * image.size.height * 4)
            decoded.setObject(image, forKey: key, cost: cost)
        }
        releaseSVGRenderSlot()
        return image
    }

    private func acquireSVGRenderSlot() async {
        if activeSVGRenderCount < 2 {
            activeSVGRenderCount += 1
            return
        }
        await withCheckedContinuation { continuation in
            svgRenderWaiters.append(continuation)
        }
    }

    private func releaseSVGRenderSlot() {
        if svgRenderWaiters.isEmpty {
            activeSVGRenderCount = max(0, activeSVGRenderCount - 1)
        } else {
            // Transfer the existing slot directly to the next waiter.
            svgRenderWaiters.removeFirst().resume()
        }
    }

    private static func isUsableLogo(_ data: Data) -> Bool {
        StationLogoFormat.svgData(from: data) != nil || UIImage(data: data) != nil
    }
}
