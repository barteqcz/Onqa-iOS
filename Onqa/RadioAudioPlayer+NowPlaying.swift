import Foundation
import MediaPlayer
import UIKit
import os

/// Produces a bounded, square bitmap for system Now Playing artwork.
///
/// SVGs arrive here after WebKit has rasterized them. Normalizing every logo
/// to the same 512 px canvas gives CarPlay and other system accessories a
/// predictable image even when the original SVG has unusual dimensions.
/// MediaPlayer asks its request handler for different sizes, so each response
/// is rasterized to the requested dimensions instead of returning the original
/// full-size image for every request.
enum NowPlayingArtworkFactory {
    private static let maximumPixelSide = 512
    private static let boundsSize = CGSize(width: 512, height: 512)

    @MainActor
    static func makeArtwork(from image: UIImage) -> MPMediaItemArtwork {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false

        let normalized = UIGraphicsImageRenderer(size: boundsSize, format: format).image { renderer in
            let canvas = CGRect(origin: .zero, size: boundsSize)
            renderer.cgContext.clear(canvas)

            let sourceSize = image.size
            guard sourceSize.width > 0, sourceSize.height > 0 else { return }

            let scale = min(
                boundsSize.width / sourceSize.width,
                boundsSize.height / sourceSize.height
            )
            let fittedSize = CGSize(
                width: sourceSize.width * scale,
                height: sourceSize.height * scale
            )
            let fittedRect = CGRect(
                x: (boundsSize.width - fittedSize.width) / 2,
                y: (boundsSize.height - fittedSize.height) / 2,
                width: fittedSize.width,
                height: fittedSize.height
            )
            image.draw(in: fittedRect)
        }

        guard let source = normalized.cgImage else {
            return MPMediaItemArtwork(boundsSize: boundsSize) { @Sendable _ in normalized }
        }

        return MPMediaItemArtwork(boundsSize: boundsSize) { @Sendable requestedSize in
            func pixelDimension(_ value: CGFloat) -> Int {
                guard value.isFinite else { return Self.maximumPixelSide }
                return Int(min(
                    CGFloat(Self.maximumPixelSide),
                    max(1, value.rounded(.up))
                ))
            }

            let width = pixelDimension(requestedSize.width)
            let height = pixelDimension(requestedSize.height)
            guard let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return normalized
            }

            let canvas = CGRect(x: 0, y: 0, width: width, height: height)
            context.clear(canvas)
            context.interpolationQuality = .high

            let scale = min(
                CGFloat(width) / CGFloat(source.width),
                CGFloat(height) / CGFloat(source.height)
            )
            let fittedSize = CGSize(
                width: CGFloat(source.width) * scale,
                height: CGFloat(source.height) * scale
            )
            let fittedRect = CGRect(
                x: (CGFloat(width) - fittedSize.width) / 2,
                y: (CGFloat(height) - fittedSize.height) / 2,
                width: fittedSize.width,
                height: fittedSize.height
            )

            // UIImage(cgImage:) applies UIKit's Core Graphics coordinate
            // correction. Flipping this context as well would invert the logo.
            context.draw(source, in: fittedRect)

            guard let rendered = context.makeImage() else { return normalized }
            return UIImage(cgImage: rendered, scale: 1, orientation: .up)
        }
    }
}

extension RadioAudioPlayer {
    nonisolated private static func addRemoteCommand(
        _ command: MPRemoteCommand,
        handler: @escaping @Sendable () -> Void
    ) {
        command.addTarget { _ in
            handler()
            return .success
        }
    }

    func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        // Re-run after a media-services reset: drop old targets so commands
        // are not handled twice.
        for command in [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand,
                        center.nextTrackCommand, center.previousTrackCommand] {
            command.removeTarget(nil)
        }
        Self.addRemoteCommand(center.playCommand) { [weak self] in
            Task { @MainActor in self?.resume() }
        }
        Self.addRemoteCommand(center.pauseCommand) { [weak self] in
            Task { @MainActor in self?.pause() }
        }
        Self.addRemoteCommand(center.togglePlayPauseCommand) { [weak self] in
            Task { @MainActor in self?.toggle() }
        }
        Self.addRemoteCommand(center.nextTrackCommand) { [weak self] in
            Task { @MainActor in self?.onNext?() }
        }
        Self.addRemoteCommand(center.previousTrackCommand) { [weak self] in
            Task { @MainActor in self?.onPrevious?() }
        }
    }

    func loadArtwork(for station: RadioStation) {
        guard let text = station.logoURL, let url = URL(string: text) else { return }
        let stationID = station.id
        Task {
            do {
                let data = try await StationImageCache.shared.data(for: url)
                let svg = StationLogoFormat.svgData(from: data)

                // UIImage cannot decode SVG. Render it through WebKit to a
                // real bitmap before handing it to the system Now Playing UI.
                let image: UIImage?
                if let svg {
                    image = await StationImageCache.shared.renderedSVG(for: url, data: svg)
                } else {
                    image = UIImage(data: data)
                }

                guard
                    self.currentStation?.id == stationID,
                    let image
                else { return }

                self.stationArtwork = NowPlayingArtworkFactory.makeArtwork(from: image)
                self.updateNowPlaying()
            } catch {
                // Artwork is optional; audio playback must not depend on image loading.
                Log.playback.debug("Artwork unavailable: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Offers the system only the commands that can act right now, instead of
    /// accepting every command and ignoring it: nothing without a station, and
    /// next/previous only when there is another station to go to.
    func updateRemoteCommandAvailability() {
        let center = MPRemoteCommandCenter.shared()
        let hasStation = currentStation != nil
        let canSkip = hasStation && hasMultipleStations
        center.playCommand.isEnabled = hasStation
        center.pauseCommand.isEnabled = hasStation
        center.togglePlayPauseCommand.isEnabled = hasStation
        center.nextTrackCommand.isEnabled = canSkip
        center.previousTrackCommand.isEnabled = canSkip
    }

    func updateNowPlaying() {
        updateRemoteCommandAvailability()
        guard let station = currentStation else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        let trimmedMetadata = metadata?.trimmingCharacters(in: .whitespacesAndNewlines)
        let liveMetadata = trimmedMetadata?.isEmpty == false ? trimmedMetadata : nil
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: liveMetadata ?? station.name,
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]
        // With live ICY data, show the track as the large title and the
        // station as its secondary line. Without metadata, show only the
        // station name so the Lock Screen and Dynamic Island stay uncluttered.
        if liveMetadata != nil {
            info[MPMediaItemPropertyArtist] = station.name
        }
        if let stationArtwork {
            info[MPMediaItemPropertyArtwork] = stationArtwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
