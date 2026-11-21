import Foundation
import MediaPlayer
import UIKit
import os

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
        guard let center = nowPlayingSession?.remoteCommandCenter else { return }
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

                self.stationArtwork = Self.makeArtwork(image)
                self.updateNowPlaying()
            } catch {
                // Artwork is optional; audio playback must not depend on image loading.
                Log.playback.debug("Artwork unavailable: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    nonisolated private static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        // MediaPlayer calls this handler on its own background queue, possibly
        // many times. Keep it trivial: no resizing or other work in here.
        MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in image }
    }

    /// Asks the system to route Now Playing info and remote commands to this
    /// app's session (Apple's documented way to promote a session).
    func becomeActiveNowPlayingSession() {
        nowPlayingSession?.becomeActiveIfPossible(completion: nil)
    }

    /// Offers the system only the commands that can act right now, instead of
    /// accepting every command and ignoring it: nothing without a station, and
    /// next/previous only when there is another station to go to.
    func updateRemoteCommandAvailability() {
        guard let center = nowPlayingSession?.remoteCommandCenter else { return }
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
            nowPlayingSession?.nowPlayingInfoCenter.nowPlayingInfo = nil
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
        nowPlayingSession?.nowPlayingInfoCenter.nowPlayingInfo = info
    }
}
