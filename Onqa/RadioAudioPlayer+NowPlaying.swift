import Foundation
import MediaPlayer
import UIKit
import os
#if canImport(NowPlaying)
import NowPlaying
#endif

// Normalize station artwork for the legacy Lock Screen and Control Center surfaces.
@MainActor
enum NowPlayingArtworkFactory {
    private static let boundsSize = CGSize(width: 512, height: 512)

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

        return MPMediaItemArtwork(boundsSize: boundsSize) { _ in normalized }
    }
}

// iOS 26 fallback. On iOS 27+, the NowPlaying framework owns all Now Playing publication.
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
        guard #unavailable(iOS 27.0) else { return }

        let center = MPRemoteCommandCenter.shared()
        for command in [
            center.playCommand,
            center.pauseCommand,
            center.togglePlayPauseCommand,
            center.nextTrackCommand,
            center.previousTrackCommand
        ] {
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

    func updateRemoteCommandAvailability() {
        guard #unavailable(iOS 27.0) else { return }

        let center = MPRemoteCommandCenter.shared()
        let hasStation = currentStation != nil
        let canSkip = hasStation && hasMultipleStations
        center.playCommand.isEnabled = hasStation
        center.pauseCommand.isEnabled = hasStation
        center.togglePlayPauseCommand.isEnabled = hasStation
        center.nextTrackCommand.isEnabled = canSkip
        center.previousTrackCommand.isEnabled = canSkip
    }

    // Legacy metadata is published only on iOS 26; do not mix it with a local MediaSession.
    func updateNowPlaying() {
        guard #unavailable(iOS 27.0) else { return }

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

        if liveMetadata != nil {
            info[MPMediaItemPropertyArtist] = station.name
        }
        if let stationArtwork {
            info[MPMediaItemPropertyArtwork] = stationArtwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func updateNowPlayingForCurrentOS() {
        #if canImport(NowPlaying)
        if #available(iOS 27.0, *) {
            activateNowPlayingSession()
        } else {
            updateNowPlaying()
        }
        #else
        updateNowPlaying()
        #endif
    }

    func clearNowPlayingForCurrentOS() {
        #if canImport(NowPlaying)
        if #available(iOS 27.0, *) {
            nowPlayingSession = nil
            return
        }
        #endif
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        updateRemoteCommandAvailability()
    }

    // Artwork loads asynchronously; discard late results when the selected station has changed.
    func loadArtwork(for station: RadioStation) {
        stationArtwork = nil
        stationArtworkData = nil
        guard let text = station.logoURL, let url = URL(string: text) else {
            updateNowPlaying()
            return
        }

        let stationID = station.id
        Task { [weak self] in
            do {
                let data = try await StationImageCache.shared.data(for: url)
                let svg = StationLogoFormat.svgData(from: data)

                let image: UIImage?
                if let svg {
                    image = await StationImageCache.shared.renderedSVG(for: url, data: svg)
                } else {
                    image = UIImage(data: data)
                }

                guard
                    let self,
                    self.currentStation?.id == stationID,
                    let image,
                    let artworkData = image.pngData()
                else { return }

                self.stationArtworkData = artworkData
                if #unavailable(iOS 27.0) {
                    self.stationArtwork = NowPlayingArtworkFactory.makeArtwork(from: image)
                    self.updateNowPlaying()
                }
            } catch {
                Log.playback.debug("Artwork unavailable: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

#if canImport(NowPlaying)
// The new local-session API is available on iOS 27 and later.
@available(iOS 27.0, *)
extension RadioAudioPlayer: MediaSessionRepresentable {
    nonisolated var id: String { "com.barteqcz.onqa.radio" }

    var content: (any MediaContentRepresentable)? {
        guard let station = currentStation else { return nil }

        let artworkData = stationArtworkData
        let artwork = artworkData.map { data in
            Artwork(id: String(describing: station.id)) { _ in
                try ArtworkRepresentation(data: data)
            }
        }

        let programName = metadata?.trimmingCharacters(in: .whitespacesAndNewlines)
        return RadioContent(
            id: String(describing: station.id),
            stationName: station.name,
            programName: programName?.isEmpty == false ? programName : nil,
            type: .audio,
            duration: .live,
            artwork: artwork
        )
    }

    var playbackSnapshot: MediaPlaybackSnapshot? {
        guard currentStation != nil else { return nil }
        return MediaPlaybackSnapshot(
            state: isPlaying ? .playing(rate: 1.0) : .paused
        )
    }

    var commands: [MediaCommand] {
        [
            .play { [weak self] in self?.resume() },
            .pause { [weak self] in self?.pause() },
            .next { [weak self] in self?.onNext?() }.enabled(hasMultipleStations),
            .previous { [weak self] in self?.onPrevious?() }.enabled(hasMultipleStations)
        ]
    }

    // Keep a single app-local session and promote it when playback starts.
    func activateNowPlayingSession() {
        guard currentStation != nil, nowPlayingSession == nil else { return }

        let session = MediaSession(self)
        nowPlayingSession = session

        Task { [weak self] in
            guard let self, self.nowPlayingSession === session else { return }
            do {
                try await session.requestToBecomeApplicationPrimary()
                guard self.nowPlayingSession === session else { return }
            } catch {
                Log.playback.error("Unable to publish Now Playing session: \(error.localizedDescription, privacy: .public)")
                if self.nowPlayingSession === session {
                    self.nowPlayingSession = nil
                }
            }
        }
    }
}
#endif
