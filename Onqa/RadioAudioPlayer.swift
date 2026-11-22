import Foundation
import AVFoundation
import MediaPlayer
import Observation
import os
import UIKit

@MainActor
@Observable
final class RadioAudioPlayer: NSObject, AVPlayerItemMetadataOutputPushDelegate {
    private(set) var currentStation: RadioStation?
    private(set) var isPlaying = false {
        didSet {
            if oldValue != isPlaying {
                onPlaybackActivityChange?()
            }
        }
    }
    private(set) var isBuffering = false
    private(set) var playbackError = false
    private(set) var isReconnecting = false
    private(set) var metadata: String?

    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onPlaybackActivityChange: (() -> Void)?

    // A var, because after a media-services reset the old AVPlayer is no
    // longer usable and is replaced (see handleMediaServicesReset).
    @ObservationIgnored private var player = AVPlayer()
    private var volumeFadeTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var stalledPlaybackTask: Task<Void, Never>?
    private var itemNotificationObservers: [NSObjectProtocol] = []
    private var playbackRequestID: UInt64 = 0
    private var shouldFadeInWhenPlaybackStarts = false
    /// While one station replaces another, AVPlayer reports intermediate states
    /// (old stream playing, then paused/waiting for the new one). Those are
    /// ignored so the UI shows a single, steady buffering state until the new
    /// stream is actually playing.
    private var holdsSwitchUI = false
    private var switchTargetItem: AVPlayerItem?
    // Every fade (in, out, and the out-before-switch) shares one duration:
    // 24 steps x 25 ms = 600 ms.
    private let volumeFadeSteps = 24
    private let volumeFadeStep: Duration = .milliseconds(25)
    /// Reconnect attempts back off from 3 s up to 30 s while a stream keeps
    /// failing, instead of retrying every 3 s indefinitely.
    private let reconnectBaseDelay: TimeInterval = 3
    private let reconnectMaxDelay: TimeInterval = 30
    private var reconnectFailures = 0
    private let stalledPlaybackRecoveryDelay: Duration = .seconds(10)
    /// Set when an audio interruption (a call, an alarm) paused playback that
    /// was active, so it can resume when the system says it should.
    private var resumeAfterInterruption = false
    private var routeChangeObserver: NSObjectProtocol?
    private var timeControlObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?
    private var metadataOutput: AVPlayerItemMetadataOutput?
    var stationArtwork: MPMediaItemArtwork?
    private var interruptionObserver: NSObjectProtocol?
    private var audioSessionIsActive = false
    private var useHQForCurrentStation = true
    private var mediaServicesResetObserver: NSObjectProtocol?
    /// After a user pause the audio session stays active for this long, so the
    /// lock-screen and Control Center play button keep working. It is then
    /// released so other apps' audio can resume.
    private let pausedSessionGracePeriod: Duration = .seconds(120)
    private var audioSessionDeactivationTask: Task<Void, Never>?
    /// Set by the store. Next/previous are only offered to the system when
    /// there is another station to switch to.
    var hasMultipleStations = false {
        didSet {
            if oldValue != hasMultipleStations { updateRemoteCommandAvailability() }
        }
    }

    override init() {
        super.init()
        configurePlayer()

        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard
                let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                let type = AVAudioSession.InterruptionType(rawValue: rawType)
            else { return }
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
                .contains(.shouldResume)
            Task { @MainActor in
                self?.handleInterruption(type, shouldResume: shouldResume)
            }
        }

        // Headphones unplugged or a Bluetooth output lost: pause, as the
        // Human Interface Guidelines ask, and release the stream.
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard
                let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                AVAudioSession.RouteChangeReason(rawValue: rawReason) == .oldDeviceUnavailable
            else { return }
            Task { @MainActor in self?.pauseAfterRouteLoss() }
        }

        // The media server daemon can crash and restart. Every AVFoundation
        // object is then stale and must be rebuilt.
        mediaServicesResetObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleMediaServicesReset() }
        }
    }

    /// Wires the current `player` to AVFoundation, MediaPlayer and the system
    /// Now Playing session. Called at launch and again after a media-services
    /// reset, when the player has been replaced.
    private func configurePlayer() {
        player.automaticallyWaitsToMinimizeStalling = true

        // Single-player app: publish through the app-wide Now Playing info
        // center and remote command center. (MPNowPlayingSession's
        // becomeActiveIfPossible fails silently, which left the Lock Screen
        // and Dynamic Island without media controls.)

        timeControlObservation = Self.observeTimeControlStatus(of: player) { [weak self] in
            Task { @MainActor in
                self?.updatePlaybackState()
            }
        }
        configureRemoteCommands()
        updateRemoteCommandAvailability()
    }

    private func handleMediaServicesReset() {
        Log.playback.error("Media services were reset; rebuilding the player")
        let station = currentStation
        let wasActive = isPlaying || isBuffering || isReconnecting

        // Invalidate every pending operation tied to the old player.
        playbackRequestID &+= 1
        resumeAfterInterruption = false
        reconnectTask?.cancel()
        reconnectTask = nil
        stalledPlaybackTask?.cancel()
        stalledPlaybackTask = nil
        volumeFadeTask?.cancel()
        volumeFadeTask = nil
        audioSessionDeactivationTask?.cancel()
        audioSessionDeactivationTask = nil
        itemStatusObservation = nil
        timeControlObservation = nil
        removeItemNotificationObservers()
        metadataOutput = nil
        holdsSwitchUI = false
        switchTargetItem = nil
        shouldFadeInWhenPlaybackStarts = false
        reconnectFailures = 0
        isReconnecting = false
        isPlaying = false
        isBuffering = false
        playbackError = false
        audioSessionIsActive = false

        player = AVPlayer()
        configurePlayer()

        if wasActive, let station {
            beginPlayback(station, useHQ: useHQForCurrentStation, preservingReconnectState: false)
        } else {
            updateNowPlaying()
        }
    }

    private func handleInterruption(_ type: AVAudioSession.InterruptionType, shouldResume: Bool) {
        switch type {
        case .began:
            let wasActive = isPlaying || isBuffering || isReconnecting
            pause()
            // pause() clears the flag, so set it afterwards.
            resumeAfterInterruption = wasActive
        case .ended:
            let shouldRestart = resumeAfterInterruption && shouldResume
            resumeAfterInterruption = false
            if shouldRestart { resume() }
        @unknown default:
            break
        }
    }

    private func pauseAfterRouteLoss() {
        guard isPlaying || isBuffering else { return }
        pause()
    }

    private func updatePlaybackState() {
        if holdsSwitchUI {
            // Right after the item is replaced AVPlayer can still report
            // .playing for a moment. Only release once the new item itself is
            // ready, so the UI never flips playing -> buffering -> playing.
            if player.timeControlStatus == .playing,
               let target = switchTargetItem,
               player.currentItem === target,
               target.status == .readyToPlay {
                holdsSwitchUI = false
                switchTargetItem = nil
            } else {
                isPlaying = false
                isBuffering = true
                updateNowPlaying()
                return
            }
        }

        isPlaying = player.timeControlStatus == .playing
        isBuffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate

        if isPlaying {
            stalledPlaybackTask?.cancel()
            stalledPlaybackTask = nil
            playbackError = false
            isReconnecting = false
            reconnectFailures = 0
            reconnectTask?.cancel()
            reconnectTask = nil

            if let item = player.currentItem {
                fadeInWhenReady(item, requestID: playbackRequestID)
            }
        }

        updateNowPlaying()
    }

    private func fadeInWhenReady(_ item: AVPlayerItem, requestID: UInt64) {
        guard
            playbackRequestID == requestID,
            player.currentItem === item,
            shouldFadeInWhenPlaybackStarts,
            item.status == .readyToPlay,
            player.timeControlStatus == .playing
        else { return }

        shouldFadeInWhenPlaybackStarts = false
        fadeInVolume(for: requestID)
    }

    var currentStreamURL: URL? { (player.currentItem?.asset as? AVURLAsset)?.url }

    func play(_ station: RadioStation, useHQ: Bool) {
        resumeAfterInterruption = false
        beginPlayback(station, useHQ: useHQ, preservingReconnectState: false)
    }

    private func beginPlayback(
        _ station: RadioStation,
        useHQ: Bool,
        preservingReconnectState: Bool
    ) {
        if !preservingReconnectState {
            reconnectTask?.cancel()
            reconnectTask = nil
            isReconnecting = false
            // A deliberate play starts a fresh series of reconnect attempts.
            reconnectFailures = 0
        }

        stalledPlaybackTask?.cancel()
        stalledPlaybackTask = nil
        playbackRequestID &+= 1
        let requestID = playbackRequestID
        holdsSwitchUI = false
        switchTargetItem = nil
        useHQForCurrentStation = useHQ
        volumeFadeTask?.cancel()
        volumeFadeTask = nil
        shouldFadeInWhenPlaybackStarts = false

        guard let url = station.streamURL(useHQ: useHQ) else {
            // Keep the selected station visible and continue retrying if its
            // stream URL is temporarily unavailable in the catalog.
            player.volume = 0
            player.pause()
            player.replaceCurrentItem(with: nil)
            itemStatusObservation = nil
            removeItemNotificationObservers()
            metadataOutput = nil
            deactivateAudioSession()
            currentStation = station
            // Drop the previous station's artwork so Now Playing never shows
            // another station's logo next to this station's name.
            stationArtwork = nil
            loadArtwork(for: station)
            metadata = nil
            isPlaying = false
            isBuffering = false
            playbackError = true
            isReconnecting = true
            reconnectFailures += 1
            updateNowPlaying()
            scheduleReconnect(for: station, useHQ: useHQ, requestID: requestID)
            return
        }

        // A stream may still be audible while AVPlayer reports that it is
        // waiting for data. Its volume, rather than timeControlStatus, tells
        // us whether a fade-out is still needed before replacing the item.
        let hasAudibleStream = player.currentItem != nil && player.volume > 0.001

        guard hasAudibleStream else {
            startPlayback(station, url: url, useHQ: useHQ, requestID: requestID)
            return
        }

        // Reflect the tap in the UI right away. Only the audio waits for the
        // outgoing station's fade-out; the selection, mini player and buffering
        // state should not lag behind the finger.
        holdsSwitchUI = true
        currentStation = station
        stationArtwork = nil
        metadata = nil
        playbackError = false
        isBuffering = true
        isPlaying = false

        volumeFadeTask = Task { [weak self] in
            guard let self else { return }
            let completed = await self.rampVolume(
                to: 0,
                steps: self.volumeFadeSteps,
                requestID: requestID
            )
            guard completed, self.playbackRequestID == requestID else { return }
            self.volumeFadeTask = nil
            self.startPlayback(station, url: url, useHQ: useHQ, requestID: requestID)
        }
    }

    private func scheduleReconnect(
        for station: RadioStation,
        useHQ: Bool,
        requestID: UInt64
    ) {
        guard
            playbackRequestID == requestID,
            currentStation?.id == station.id,
            isReconnecting,
            reconnectTask == nil
        else { return }

        let delay = RetryBackoff.delay(
            afterFailures: reconnectFailures,
            base: reconnectBaseDelay,
            cap: reconnectMaxDelay
        )
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }

            guard
                !Task.isCancelled,
                self.playbackRequestID == requestID,
                self.currentStation?.id == station.id,
                self.isReconnecting
            else { return }

            self.reconnectTask = nil
            self.beginPlayback(
                station,
                useHQ: useHQ,
                preservingReconnectState: true
            )
        }
    }

    private func scheduleStalledPlaybackRecovery(
        for station: RadioStation,
        useHQ: Bool,
        requestID: UInt64,
        item: AVPlayerItem
    ) {
        guard
            playbackRequestID == requestID,
            player.currentItem === item
        else { return }

        stalledPlaybackTask?.cancel()
        stalledPlaybackTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: self.stalledPlaybackRecoveryDelay)
            } catch {
                return
            }

            guard
                !Task.isCancelled,
                self.playbackRequestID == requestID,
                self.player.currentItem === item,
                self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            else { return }

            self.stalledPlaybackTask = nil
            Log.playback.error("Playback remained stalled for \(station.name, privacy: .public); rebuilding stream")
            self.handlePlaybackFailure(
                for: station,
                useHQ: useHQ,
                requestID: requestID,
                item: item
            )
        }
    }

    private func removeItemNotificationObservers() {
        stalledPlaybackTask?.cancel()
        stalledPlaybackTask = nil
        for observer in itemNotificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        itemNotificationObservers.removeAll()
    }

    private func handlePlaybackFailure(
        for station: RadioStation,
        useHQ: Bool,
        requestID: UInt64,
        item: AVPlayerItem
    ) {
        guard
            playbackRequestID == requestID,
            player.currentItem === item
        else { return }

        Log.playback.error("Playback failed for \(station.name, privacy: .public); scheduling reconnect")
        shouldFadeInWhenPlaybackStarts = false
        holdsSwitchUI = false
        switchTargetItem = nil
        volumeFadeTask?.cancel()
        volumeFadeTask = nil

        player.volume = 0
        player.pause()
        player.replaceCurrentItem(with: nil)
        itemStatusObservation = nil
        removeItemNotificationObservers()
        metadataOutput = nil

        isPlaying = false
        isBuffering = false
        playbackError = true
        isReconnecting = true
        reconnectFailures += 1
        updateNowPlaying()
        scheduleReconnect(for: station, useHQ: useHQ, requestID: requestID)
    }

    /// Rebuild the active stream after connectivity returns. A stream can be
    /// stuck waiting for data without ever entering the explicit reconnect state.
    func retryNow() {
        guard
            let station = currentStation,
            isReconnecting
                || isBuffering
                || player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        stalledPlaybackTask?.cancel()
        stalledPlaybackTask = nil
        // Connectivity just returned, so retry immediately and start the
        // backoff series over.
        reconnectFailures = 0
        beginPlayback(
            station,
            useHQ: useHQForCurrentStation,
            preservingReconnectState: true
        )
    }

    private func activateAudioSession() -> Bool {
        audioSessionDeactivationTask?.cancel()
        audioSessionDeactivationTask = nil
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
            audioSessionIsActive = true
            return true
        } catch {
            Log.playback.error("Unable to activate audio session: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Keeps the session alive for a short grace period after a user pause,
    /// then releases it. A new playback cancels the pending release.
    private func scheduleAudioSessionDeactivation() {
        audioSessionDeactivationTask?.cancel()
        guard audioSessionIsActive else { return }
        audioSessionDeactivationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: self.pausedSessionGracePeriod)
            } catch {
                return
            }
            guard !self.isPlaying, !self.isBuffering, !self.isReconnecting else { return }
            self.audioSessionDeactivationTask = nil
            self.deactivateAudioSession()
        }
    }

    private func deactivateAudioSession() {
        audioSessionDeactivationTask?.cancel()
        audioSessionDeactivationTask = nil
        guard audioSessionIsActive else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(
                false,
                options: [.notifyOthersOnDeactivation]
            )
            audioSessionIsActive = false
        } catch {
            Log.playback.error("Unable to deactivate audio session: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func startPlayback(
        _ station: RadioStation,
        url: URL,
        useHQ: Bool,
        requestID: UInt64
    ) {
        guard playbackRequestID == requestID else { return }

        useHQForCurrentStation = useHQ
        itemStatusObservation = nil
        removeItemNotificationObservers()
        metadataOutput = nil
        stationArtwork = nil
        currentStation = station
        loadArtwork(for: station)
        metadata = nil
        playbackError = false
        isBuffering = true
        isPlaying = false

        // A station switch may still have the previous (now silent) item
        // installed. Release it before attempting activation so a failed
        // activation cannot leave a hidden player running underneath the error.
        player.volume = 0
        player.pause()
        player.replaceCurrentItem(with: nil)

        guard activateAudioSession() else {
            deactivateAudioSession()
            holdsSwitchUI = false
            switchTargetItem = nil
            isPlaying = false
            isBuffering = false
            isReconnecting = false
            playbackError = true
            updateNowPlaying()
            return
        }

        let item = AVPlayerItem(url: url)
        if holdsSwitchUI { switchTargetItem = item }
        let output = AVPlayerItemMetadataOutput(identifiers: nil)
        output.setDelegate(self, queue: .main)
        item.add(output)
        metadataOutput = output

        itemStatusObservation = Self.observeStatus(of: item) { [weak self] observedItem in
            guard observedItem.status == .readyToPlay || observedItem.status == .failed else { return }
            Task { @MainActor in
                guard let self else { return }
                if observedItem.status == .failed {
                    self.handlePlaybackFailure(
                        for: station,
                        useHQ: useHQ,
                        requestID: requestID,
                        item: observedItem
                    )
                } else {
                    // The item may become ready after the player already
                    // reports .playing; re-evaluate so a held switch releases.
                    if self.playbackRequestID == requestID {
                        self.updatePlaybackState()
                    }
                    self.fadeInWhenReady(observedItem, requestID: requestID)
                }
            }
        }

        // A stall is recoverable: AVPlayer automatically waits for data and resumes.
        // Reconnect only when the item reports an actual playback failure.
        let failureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handlePlaybackFailure(
                    for: station,
                    useHQ: useHQ,
                    requestID: requestID,
                    item: item
                )
            }
        }
        itemNotificationObservers.append(failureObserver)

        // AVPlayer normally resumes a stalled stream itself. If it remains
        // waiting, rebuild the item after a grace period rather than buffering
        // indefinitely. A successful resume cancels this recovery task.
        let stalledObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleStalledPlaybackRecovery(
                    for: station,
                    useHQ: useHQ,
                    requestID: requestID,
                    item: item
                )
            }
        }
        itemNotificationObservers.append(stalledObserver)

        volumeFadeTask?.cancel()
        volumeFadeTask = nil
        player.volume = 0
        shouldFadeInWhenPlaybackStarts = true

        player.replaceCurrentItem(with: item)
        player.play()
        updateNowPlaying()
    }

    func pause() {
        playbackRequestID &+= 1
        let requestID = playbackRequestID
        resumeAfterInterruption = false
        holdsSwitchUI = false
        switchTargetItem = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        isReconnecting = false
        reconnectFailures = 0
        playbackError = false
        shouldFadeInWhenPlaybackStarts = false
        volumeFadeTask?.cancel()
        volumeFadeTask = nil

        guard player.currentItem != nil else {
            player.pause()
            isPlaying = false
            isBuffering = false
            scheduleAudioSessionDeactivation()
            updateNowPlaying()
            return
        }

        guard player.timeControlStatus == .playing, player.volume > 0.001 else {
            finishPause()
            return
        }

        volumeFadeTask = Task { [weak self] in
            guard let self else { return }
            let completed = await self.rampVolume(
                to: 0,
                steps: self.volumeFadeSteps,
                requestID: requestID
            )
            guard completed, self.playbackRequestID == requestID else { return }
            self.volumeFadeTask = nil
            self.finishPause()
        }
    }

    private func finishPause() {
        player.volume = 0
        player.pause()
        // Release the current item so the HTTP stream connection is closed.
        // resume() creates a fresh AVPlayerItem instead of continuing the old stream.
        player.replaceCurrentItem(with: nil)
        itemStatusObservation = nil
        removeItemNotificationObservers()
        metadataOutput = nil
        isPlaying = false
        isBuffering = false
        playbackError = false
        isReconnecting = false
        volumeFadeTask = nil
        scheduleAudioSessionDeactivation()
        updateNowPlaying()
    }

    private func fadeInVolume(for requestID: UInt64) {
        volumeFadeTask?.cancel()
        volumeFadeTask = Task { [weak self] in
            guard let self else { return }
            let completed = await self.rampVolume(
                to: 1,
                steps: self.volumeFadeSteps,
                requestID: requestID
            )
            guard completed, self.playbackRequestID == requestID else { return }
            self.volumeFadeTask = nil
        }
    }

    private func rampVolume(
        to target: Float,
        steps: Int,
        requestID: UInt64
    ) async -> Bool {
        let startingVolume = player.volume
        for step in 1...max(1, steps) {
            do {
                try await Task.sleep(for: volumeFadeStep)
            } catch {
                return false
            }
            guard !Task.isCancelled, playbackRequestID == requestID else { return false }

            let progress = Float(step) / Float(max(1, steps))
            player.volume = startingVolume + (target - startingVolume) * progress
        }
        player.volume = target
        return true
    }

    func resume() {
        guard let station = currentStation else { return }
        play(station, useHQ: useHQForCurrentStation)
    }

    func toggle() {
        if isReconnecting || isPlaying || isBuffering { pause() } else { resume() }
    }

    func stop() {
        playbackRequestID &+= 1
        resumeAfterInterruption = false
        holdsSwitchUI = false
        switchTargetItem = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        isReconnecting = false
        reconnectFailures = 0
        stationArtwork = nil
        shouldFadeInWhenPlaybackStarts = false
        volumeFadeTask?.cancel()
        volumeFadeTask = nil
        player.volume = 0
        player.pause()
        player.replaceCurrentItem(with: nil)
        itemStatusObservation = nil
        removeItemNotificationObservers()
        metadataOutput = nil
        currentStation = nil
        metadata = nil
        isPlaying = false
        isBuffering = false
        playbackError = false
        deactivateAudioSession()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        updateRemoteCommandAvailability()
    }

    // AVFoundation calls this on the output's delegate queue. The protocol
    // requires a Sendable conformer, so it cannot be main-actor isolated.
    nonisolated func metadataOutput(
        _ output: AVPlayerItemMetadataOutput,
        didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup],
        from track: AVPlayerItemTrack?
    ) {
        // Streams publish several string items (title, station name, URL,
        // genre ...). Only the ones that carry a track title are used. The
        // strings are read here, on the delegate queue, so only Sendable
        // Strings cross into the main actor and AVMetadataItem never does.
        // (stringValue is deprecated, but timed-metadata items delivered by
        // this output are already loaded, so the synchronous read is valid.)
        let title = groups
            .flatMap(\.items)
            .filter { StreamMetadata.isTrackTitle(identifier: $0.identifier?.rawValue) }
            .compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        guard let title else { return }
        let source = ObjectIdentifier(output)
        Task { @MainActor [weak self] in
            self?.applyMetadata(title, from: source)
        }
    }

    private func applyMetadata(_ title: String, from source: ObjectIdentifier) {
        // A callback from a stream that has since been replaced must not
        // overwrite the new station's metadata.
        guard let current = metadataOutput, ObjectIdentifier(current) == source else { return }
        metadata = title
        updateNowPlaying()
    }

    // AVFoundation and MediaPlayer invoke these callbacks on their own
    // background queues. Closures created inside this @MainActor class would
    // be inferred as main-actor isolated and trip a runtime isolation check
    // (a crash) the first time the system calls them, e.g. when the player
    // starts playing about a second after a station is selected. Building
    // them in nonisolated helpers keeps them off the main actor; each one
    // hops to the main actor explicitly.
    nonisolated private static func observeTimeControlStatus(
        of player: AVPlayer,
        handler: @escaping @Sendable () -> Void
    ) -> NSKeyValueObservation {
        player.observe(\.timeControlStatus, options: [.initial, .new]) { _, _ in
            handler()
        }
    }

    nonisolated private static func observeStatus(
        of item: AVPlayerItem,
        handler: @escaping @Sendable (AVPlayerItem) -> Void
    ) -> NSKeyValueObservation {
        item.observe(\.status, options: [.initial, .new]) { observedItem, _ in
            handler(observedItem)
        }
    }
}
