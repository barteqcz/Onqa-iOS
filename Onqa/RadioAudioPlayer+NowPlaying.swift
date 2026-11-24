import Foundation
import NowPlaying

// The system Now Playing framework observes this model and publishes radio metadata,
// playback state, artwork, and transport commands to Lock Screen, Control Center, and Dynamic Island.
extension RadioAudioPlayer: MediaSessionRepresentable {
    var id: String { "com.barteqcz.onqa.radio" }

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

    // A local session must be made system-primary while the app is in the foreground.
    // Keep it alive across pauses and reconnects; clear it only when playback is stopped.
    func activateNowPlayingSession() {
        guard nowPlayingSession == nil else { return }

        let session = MediaSession(self)
        nowPlayingSession = session

        Task { [weak self] in
            do {
                try await session.requestToBecomeSystemPrimary()
            } catch {
                Log.playback.error("Unable to publish Now Playing session: \(error.localizedDescription, privacy: .public)")
                if self?.nowPlayingSession === session {
                    self?.nowPlayingSession = nil
                }
            }
        }
    }
}
