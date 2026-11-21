import SwiftUI
import MapKit
import UIKit
import Observation

// MARK: - Misc components

/// Card shown in the list area, in place of the loading spinner and the "No
/// stations found" card, while the station catalog downloads or, on the very
/// first launch, when there is no internet connection to download it with.
/// It uses the same surface as `EmptyStationsView` so the swap is seamless.
struct CatalogStatusView: View {
    let status: CatalogStatus
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            switch status {
            case .downloading:
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.large)
                Text("Downloading radio catalog")
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text("This can take a while on a slow connection. Stations will appear as soon as it finishes.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            case .offline:
                Image(systemName: "wifi.slash")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.orange)
                Text("No internet connection")
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text("Onqa needs to download its radio catalog once. Connect to the internet and the download will start automatically.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                // Standard system button, neutral rather than accent-colored.
                Button("Retry", action: onRetry)
                    .buttonStyle(.bordered)
                    .tint(Color.primary)
                    .padding(.top, 4)
            }
        }
        .animation(.snappy(duration: 0.24), value: status)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 40)
        .background(Palette.stationCardSurface, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).stroke(Palette.outline, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
}

struct LocationLoadingView: View {
    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(.circular)
            Text("Finding nearby stations")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .accessibilityElement(children: .combine)
    }
}

struct EmptyStationsView: View {
    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("👀")
                .font(.largeTitle)
            Text("No stations found")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 24)
        .padding(.vertical, 48)
        .background(Palette.stationCardSurface, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).stroke(Palette.outline, lineWidth: 1))
    }
}

struct StatusBanner: View {
    let message: String
    let systemImage: String
    var tint: Color = .orange
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
            Text(message)
                .font(.caption.weight(.medium))
                .lineLimit(2)
            Spacer(minLength: 4)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.caption.weight(.bold))
            }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
