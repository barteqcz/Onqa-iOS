import SwiftUI
import MapKit
import UIKit
import Observation

// A measured, looping ticker keeps long live-track titles readable without changing the mini-player layout.
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

// Animate the current card out before changing stations, then bring the replacement card back into view.
private struct MiniPlayerSwipe: ViewModifier {
    let isEnabled: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void

    @State private var offsetX: CGFloat = 0
    @State private var opacity: Double = 1
    @State private var size: CGSize = .zero
    private enum Phase { case idle, slidingOut, slidingIn }
    @State private var phase: Phase = .idle

    @State private var generation = 0
    @State private var hapticTrigger = 0

    @GestureState private var isDragging = false

    private let distanceThreshold: CGFloat = 50
    private let flickThreshold: CGFloat = 120
    private let resistance: CGFloat = 0.6
    private let slideOut: Duration = .milliseconds(130)
    private let slideIn: Duration = .milliseconds(340)

    func body(content: Content) -> some View {
        ZStack {

            Color.clear
                .frame(width: size.width, height: size.height)
                .contentShape(Rectangle())
                .onTapGesture {}

            content
                .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
                .offset(x: offsetX)
                .opacity(opacity)
        }

        .simultaneousGesture(isEnabled ? swipe : nil)
        .onChange(of: isDragging) { _, dragging in
            if !dragging && phase == .idle && offsetX != 0 { springBack() }
        }
        .sensoryFeedback(.impact(flexibility: .soft), trigger: hapticTrigger)
        .accessibilityAction(named: Text("Previous station")) {
            if isEnabled { onPrevious() }
        }
        .accessibilityAction(named: Text("Next station")) {
            if isEnabled { onNext() }
        }
    }

    private func isHorizontal(_ value: DragGesture.Value) -> Bool {
        abs(value.translation.width) > abs(value.translation.height)
    }

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 12)
            .updating($isDragging) { _, state, _ in state = true }
            .onChanged { value in
                guard phase == .idle, isHorizontal(value) else { return }
                offsetX = value.translation.width * resistance
            }
            .onEnded { value in
                guard phase != .slidingOut else { return }
                let drag = value.translation.width
                let flick = value.predictedEndTranslation.width
                guard isHorizontal(value) else { return springBack() }

                if drag < -distanceThreshold || flick < -flickThreshold {
                    commit(direction: -1, action: onNext)
                } else if drag > distanceThreshold || flick > flickThreshold {
                    commit(direction: 1, action: onPrevious)
                } else {
                    springBack()
                }
            }
    }

    private func springBack() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { offsetX = 0 }
    }

    private func commit(direction: CGFloat, action: @escaping () -> Void) {

        generation += 1
        let current = generation
        phase = .slidingOut
        hapticTrigger += 1

        withAnimation(.easeIn(duration: 0.13)) {
            offsetX = direction * size.width
            opacity = 0
        }

        Task { @MainActor in
            try? await Task.sleep(for: slideOut)

            action()
            var jump = Transaction()
            jump.disablesAnimations = true
            withTransaction(jump) {
                offsetX = -direction * size.width * 0.6
                opacity = 0
            }

            phase = .slidingIn
            withAnimation(.spring(response: 0.34, dampingFraction: 0.85)) {
                offsetX = 0
                opacity = 1
            }
            try? await Task.sleep(for: slideIn)
            if generation == current { phase = .idle }
        }
    }
}

/// Compact playback surface shared across the app, including track metadata and station-swipe controls.
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

            .modifier(
                MiniPlayerSwipe(
                    isEnabled: player.hasMultipleStations,
                    onPrevious: store.playPrevious,
                    onNext: store.playNext
                )
            )

            .transaction(value: isFavorite) { $0.animation = nil }
        }
    }
}
