import SwiftUI
import MapKit
import UIKit
import Observation

/// Outlined "HQ" tag shown next to stations that offer a high-quality stream.
struct HQBadge: View {
    let color: Color

    var body: some View {
        Text("HQ")
            .font(.footnote.weight(.bold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(color.opacity(0.7), lineWidth: 1.2)
            )
    }
}

/// A standalone station box. The button, context menu and accessibility
/// actions are native SwiftUI controls; only the box's visual surface is custom.
struct StationCardView: View {
    let station: RadioStation
    let isActive: Bool
    let isPlaying: Bool
    let distanceUnit: DistanceUnit
    let accent: Color
    let onPlay: () -> Void
    let onFavorite: () -> Void

    private var stationAccent: Color {
        station.isFavorite ? Palette.favoriteAccent : accent
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
    }

    private var distanceText: String? {
        guard let km = station.distanceKm else { return nil }
        return distanceUnit.formatted(kilometers: km)
    }

    private var chipText: String? {
        var parts: [String] = []
        if let transmitter = station.transmitterName, !transmitter.isEmpty {
            parts.append(transmitter)
        }
        if let distanceText {
            parts.append(distanceText)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    var body: some View {
        Button(action: onPlay) {
            cardContent
        }
        .buttonStyle(StationCardButtonStyle())
        .contextMenu {
            Button(action: onPlay) {
                Label(isPlaying ? "Pause" : "Play", systemImage: isPlaying ? "pause.fill" : "play.fill")
            }
            Button(action: onFavorite) {
                Label(
                    station.isFavorite ? "Remove from Favorites" : "Add to Favorites",
                    systemImage: station.isFavorite ? "heart.slash" : "heart"
                )
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: isActive)
        .sensoryFeedback(.success, trigger: station.isFavorite)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(station.name)
        .accessibilityHint("Tap to play. Touch and hold to add or remove from favorites.")
        .accessibilityAction(.default, onPlay)
        .accessibilityAction(
            named: station.isFavorite ? Text("Remove from Favorites") : Text("Add to Favorites"),
            onFavorite
        )
        .animation(.spring(response: 0.34, dampingFraction: 0.84), value: isActive)
        .animation(.snappy(duration: 0.22), value: isPlaying)
        .animation(.snappy(duration: 0.22), value: station.isFavorite)
    }

    private var cardContent: some View {
        HStack(spacing: 12) {
            StationLogo(url: station.logoURL, size: 60, accent: stationAccent)

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(station.name)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)

                    if station.streamURLHQ?.isEmpty == false {
                        HQBadge(color: stationAccent)
                    }
                }

                if let chipText {
                    Text(chipText)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(stationAccent)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            stationAccent.opacity(0.13),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                }
            }

            Spacer(minLength: 0)

            if isActive && isPlaying {
                Image(systemName: "waveform")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(stationAccent)
                    .symbolEffect(.variableColor.iterative.reversing, isActive: true)
                    .transition(.scale(scale: 0.78).combined(with: .opacity))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                shape.fill(Palette.stationCardSurface)
                if station.isFavorite {
                    shape.fill(Palette.favoriteAccent.opacity(0.11))
                } else if isActive {
                    shape.fill(stationAccent.opacity(0.16))
                }
            }
        }
        .overlay {
            shape.stroke(
                station.isFavorite || isActive ? stationAccent.opacity(0.65) : Palette.outline,
                lineWidth: station.isFavorite || isActive ? 1.5 : 1
            )
        }
        .contentShape(shape)
    }
}

extension StationCardView: Equatable {
    nonisolated static func == (lhs: StationCardView, rhs: StationCardView) -> Bool {
        lhs.station == rhs.station
            && lhs.isActive == rhs.isActive
            && lhs.isPlaying == rhs.isPlaying
            && lhs.distanceUnit == rhs.distanceUnit
            && lhs.accent == rhs.accent
    }
}

private struct StationCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.965 : 1)
            .animation(.spring(response: 0.24, dampingFraction: 0.62), value: configuration.isPressed)
    }
}
