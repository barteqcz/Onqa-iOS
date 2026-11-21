import SwiftUI
import MapKit
import UIKit
import Observation

// MARK: - Mini player metadata

/// Keeps short ICY titles still, and gently scrolls longer ones in a seamless loop.
private struct MiniPlayerMetadataView: View {
    let text: String
    let color: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .subheadline) private var lineHeight: CGFloat = 20
    @State private var contentWidth: CGFloat = 0
    @State private var startDate = Date()

    private let spacing: CGFloat = 28
    private let scrollSpeed: CGFloat = 26
    private let pauseAtStart: TimeInterval = 1.1

    private var measuredText: some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .onGeometryChange(for: CGFloat.self) { geometry in
                geometry.size.width
            } action: { width in
                contentWidth = width
            }
    }

    var body: some View {
        GeometryReader { geometry in
            let distance = contentWidth + spacing
            let shouldScroll = !reduceMotion && contentWidth > geometry.size.width + 1
            let travelDuration = max(1, Double(distance / scrollSpeed))
            let cycleDuration = pauseAtStart + travelDuration
            TimelineView(.animation(paused: !shouldScroll)) { timeline in
                let elapsed = max(0, timeline.date.timeIntervalSince(startDate))
                let phase = shouldScroll ? elapsed.truncatingRemainder(dividingBy: cycleDuration) : 0
                let progress = phase <= pauseAtStart
                    ? 0
                    : min(1, (phase - pauseAtStart) / travelDuration)
                let offset = shouldScroll ? -distance * CGFloat(progress) : 0

                HStack(spacing: spacing) {
                    measuredText
                    if shouldScroll {
                        measuredText
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
                .offset(x: offset)
                .frame(height: geometry.size.height, alignment: .leading)
                .clipped()
            }
        }
        .onChange(of: text) { _, _ in startDate = Date() }
        .frame(height: lineHeight)
        .clipped()
        .accessibilityLabel(text)
    }
}

// MARK: - Mini player

struct MiniPlayerView: View {
    let store: RadioStore
    let player: RadioAudioPlayer

    private var isFavorite: Bool {
        guard let station = player.currentStation else { return false }
        return store.favorites.contains(station.id)
    }

    private var accent: Color {
        isFavorite ? Palette.favoriteAccent : store.settings.accent.swiftUIColor
    }

    var body: some View {
        if let station = player.currentStation {
            let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
            HStack(spacing: 12) {
                HStack(spacing: 12) {
                    StationLogo(url: station.logoURL, size: 60, accent: accent)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(station.name)
                                .font(.title3.weight(.bold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                            if station.streamURLHQ?.isEmpty == false {
                                HQBadge(color: accent)
                            }
                        }
                        if player.isPlaying,
                           let metadata = player.metadata?.trimmingCharacters(in: .whitespacesAndNewlines),
                           !metadata.isEmpty {
                            MiniPlayerMetadataView(text: metadata, color: accent)
                                .id(metadata)
                                .transition(
                                    .asymmetric(
                                        insertion: .move(edge: .bottom).combined(with: .opacity),
                                        removal: .opacity
                                    )
                                )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .clipped()
                    .animation(.spring(response: 0.32, dampingFraction: 0.86), value: player.metadata)
                    .animation(.easeInOut(duration: 0.18), value: player.isPlaying)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if player.isReconnecting {
                    Button {
                        player.toggle()
                    } label: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 23, weight: .bold))
                            .foregroundStyle(.yellow)
                            .frame(width: 52, height: 52)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Reconnecting…"))
                    .accessibilityHint(String(localized: "Pause"))
                } else if player.isBuffering {
                    ProgressView()
                        .frame(width: 52, height: 52)
                        .accessibilityLabel(String(localized: "Buffering…"))
                } else {
                    Button {
                        player.toggle()
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(Color.primary)
                            .frame(width: 52, height: 52)
                            .contentShape(Rectangle())
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: player.isPlaying ? "Pause" : "Play"))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .onqaGlass(
                shape,
                tint: player.isReconnecting
                    ? Color.yellow.opacity(0.18)
                    : (player.isPlaying ? accent.opacity(0.10) : nil),
                interactive: true
            )
            .animation(.easeInOut(duration: 0.2), value: player.isPlaying)
            // Make the whole player a hit target so taps on its empty areas
            // do not fall through to the station cards scrolling behind it.
            .contentShape(shape)
            .onTapGesture {}
            .id(station.id)
            .transition(
                .asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.96)),
                    removal: .opacity
                )
            )
            .animation(.spring(response: 0.42, dampingFraction: 0.82), value: station.id)
        }
    }
}
