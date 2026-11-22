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

// MARK: - Mini player swipe

/// Horizontal swipe on the mini player: right plays the previous station,
/// left plays the next one.
///
/// The bar follows the finger, then on commit slides out in the swipe
/// direction, the station changes while it is off-screen, and the new bar
/// slides in from the opposite side. All state lives here (outside the
/// `.id(station.id)` rebuild) so the motion is continuous.
private struct MiniPlayerSwipe: ViewModifier {
    let isEnabled: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void

    @State private var offsetX: CGFloat = 0
    @State private var opacity: Double = 1
    @State private var width: CGFloat = 400
    private enum Phase { case idle, slidingOut, slidingIn }
    @State private var phase: Phase = .idle
    /// Bumped on every commit so a superseded slide-in never resets state.
    @State private var generation = 0
    @State private var hapticTrigger = 0
    /// Only used to notice a cancelled drag (e.g. a system interruption).
    @GestureState private var isDragging = false

    private let distanceThreshold: CGFloat = 50
    private let flickThreshold: CGFloat = 120
    private let resistance: CGFloat = 0.6
    private let slideOut: Duration = .milliseconds(130)
    private let slideIn: Duration = .milliseconds(340)

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .offset(x: offsetX)
            .opacity(opacity)
            // simultaneous so the play/pause button and the hit-target tap keep working
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
                    commit(direction: -1, action: onNext)       // left -> next
                } else if drag > distanceThreshold || flick > flickThreshold {
                    commit(direction: 1, action: onPrevious)   // right -> previous
                } else {
                    springBack()
                }
            }
    }

    private func springBack() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { offsetX = 0 }
    }

    private func commit(direction: CGFloat, action: @escaping () -> Void) {
        // A swipe is accepted while the previous slide-in is still running,
        // so stations can be skipped quickly; the new slide-out simply
        // starts from wherever the bar currently is.
        generation += 1
        let current = generation
        phase = .slidingOut
        hapticTrigger += 1

        // 1. Slide the current bar out in the swipe direction.
        withAnimation(.easeIn(duration: 0.13)) {
            offsetX = direction * width
            opacity = 0
        }

        Task { @MainActor in
            try? await Task.sleep(for: slideOut)

            // 2. Switch station while the bar is off-screen and park the
            //    new bar on the opposite side, without animating.
            action()
            var jump = Transaction()
            jump.disablesAnimations = true
            withTransaction(jump) {
                offsetX = -direction * width * 0.6
                opacity = 0
            }

            // 3. Slide the new bar in. Input is accepted again right away.
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
            // Applied outside `.id(station.id)` on purpose: the drag offset must
            // survive the station change, otherwise the freshly inserted bar
            // starts at 0 and the release looks like a jump instead of a
            // smooth spring back.
            .modifier(
                MiniPlayerSwipe(
                    isEnabled: player.hasMultipleStations,
                    onPrevious: store.playPrevious,
                    onNext: store.playNext
                )
            )
        }
    }
}
