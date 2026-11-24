import SwiftUI
import UIKit

struct StationLogo: View {
    let url: String?
    let size: CGFloat
    let accent: Color

    @State private var image: UIImage?
    @Environment(\.displayScale) private var displayScale

    private var logoURL: URL? {
        guard let url else { return nil }
        return URL(string: url)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .background(Color.primary.opacity(0.06))
        .clipShape(shape)
        .accessibilityHidden(true)
        .task(id: url) {
            image = nil
            guard let logoURL else { return }
            do {
                let data = try await StationImageCache.shared.data(for: logoURL)
                guard !Task.isCancelled else { return }

                if let svg = StationLogoFormat.svgData(from: data) {

                    let rendered = await StationImageCache.shared.renderedSVG(for: logoURL, data: svg)
                    guard !Task.isCancelled else { return }
                    image = rendered
                } else {
                    let thumb = await StationImageCache.shared.thumbnail(
                        for: logoURL, data: data, maxPixel: size * displayScale
                    )
                    guard !Task.isCancelled else { return }
                    image = thumb
                }
            } catch {

            }
        }
    }

    private var fallback: some View {
        Image(systemName: "dot.radiowaves.left.and.right")
            .font(.system(size: size * 0.36, weight: .medium))
            .foregroundStyle(accent.opacity(0.8))
    }
}
