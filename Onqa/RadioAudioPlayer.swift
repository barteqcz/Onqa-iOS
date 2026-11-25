import Foundation
import AVFoundation
import MediaPlayer
#if canImport(NowPlaying)
import NowPlaying
#endif
import Observation
import os

enum StationSwitchFadePolicy {
    static func volume(startingVolume: Float, step: Int, steps: Int) -> Float {
        let totalSteps = max(1, steps)
        let clampedStep = min(max(step, 0), totalSteps)
        let progress = Float(clampedStep) / Float(totalSteps)
        return startingVolume * (1 - progress)
    }
}

/// Main-actor owner of AVPlayer, audio-session lifecycle, stream metadata, and automatic recovery.
/// `playbackRequestID` invalidates callbacks and tasks that belong to an older station request.
@MainActor
@Observable
final class RadioAudioPlayer: NSObject, AVPlayerItemMetadataOutputPushDelegate {
    private(set) var currentStation: RadioStation? {
        didSet { updateNowPlaying() }
    }
    private(set) var isPlaying = false {
        didSet {
            if oldValue != isPlaying {
                onPlaybackActivityChange?()
                updateNowPlaying()
            }
        }
    }
    private(set) var isBuffering = false {
        didSet {
            if oldValue != isBuffering {
                onPlaybackActivityChange?()
                updateNowPlaying()
            }
        }
    }
    private(set) var playbackError = false
    private(set) var isReconnecting = false {
        didSet {
            if oldValue != isReconnecting {
                onPlaybackActivityChange?()
                updateNowPlaying()
            }
        }
    }
    private(set) var metadata: String? {
        didSet {
            if oldValue != metadata { updateNowPlaying() }
        }
    }

    /// Reconnect attempts stop counting as active playback after a few failures so a dead stream
    /// cannot hold background location (the blue arrow) forever without any audio.
    var hasActivePlayback: Bool {
        isPlaying || isBuffering || (isReconnecting && reconnectFailures < backgroundReconnectFailureLimit)
    }

    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onPlaybackActivityChange: (() -> Void)?

    @ObservationIgnored private var player = AVPlayer()
    private var outgoingPlayer: AVPlayer?
    private var outgoingFadeTask: Task<Void, Never>?
    private var volumeFadeTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var stalledPlaybackTask: Task<Void, Never>?
    private var itemNotificationObservers: [NSObjectProtocol] = []
    private var playbackRequestID: UInt64 = 0
    private var shouldFadeInWhenPlaybackStarts = false

    private let volumeFadeSteps = 24
    // Start above silence so background audio is already audible before the optional fade-in runs.
    private let startupPlaybackVolume: Float = 0.12
    private let volumeFadeStep: Duration = .milliseconds(25)

    private let reconnectBaseDelay: TimeInterval = 3
    private let reconnectMaxDelay: TimeInterval = 30
    private var reconnectFailures = 0
    private let stalledPlaybackRecoveryDelay: Duration = .seconds(10)
    private let backgroundReconnectFailureLimit = 4
    // Keep the (paused) audio session briefly so Lock Screen / Dynamic Island controls stay available.
    private let pausedSessionLinger: Duration = .seconds(300)
    private var sessionDeactivationTask: Task<Void, Never>?
    // True from a play request until an explicit pause/stop; unaffected by system-initiated pauses.
    private var intendsToPlay = false
    @ObservationIgnored var isApplicationActive = true

    private var resumeAfterInterruption = false
    private var routeChangeObserver: NSObjectProtocol?
    private var timeControlObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?
    private var metadataOutput: AVPlayerItemMetadataOutput?
    var stationArtworkData: Data?
    var stationArtwork: MPMediaItemArtwork?
    #if canImport(NowPlaying)
    // Type-erased storage keeps the iOS 27-only framework type out of the Observation macro expansion.
    @ObservationIgnored
    var nowPlayingSessionStorage: AnyObject?
    @ObservationIgnored var nowPlayingPromotionTask: Task<Void, Never>?
    @ObservationIgnored var nowPlayingPromotionGeneration: UInt64 = 0
    #endif
    private var interruptionObserver: NSObjectProtocol?
    private var audioSessionIsActive = false
    private var useHQForCurrentStation = true
    private var mediaServicesResetObserver: NSObjectProtocol?


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

        mediaServicesResetObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleMediaServicesReset() }
        }
    }

    private func configurePlayer() {
        player.automaticallyWaitsToMinimizeStalling = true
        observePlaybackState(of: player)

        if #unavailable(iOS 27.0) {
            configureRemoteCommands()
            updateRemoteCommandAvailability()
        }
    }

    private func observePlaybackState(of observedPlayer: AVPlayer) {
        timeControlObservation = Self.observeTimeControlStatus(of: observedPlayer) { [weak self, weak observedPlayer] in
            Task { @MainActor in
                guard let self, let observedPlayer, self.player === observedPlayer else { return }
                self.updatePlaybackState()
            }
        }
    }

    private func stopOutgoingPlayer() {
        outgoingFadeTask?.cancel()
        outgoingFadeTask = nil
        outgoingPlayer?.volume = 0
        outgoingPlayer?.pause()
        outgoingPlayer?.replaceCurrentItem(with: nil)
        outgoingPlayer = nil
    }

    // Keep the old stream on its own AVPlayer while the replacement starts immediately.
    // This preserves the station-switch fade without making startup wait for the fade to finish.
    private func prepareForStationSwitch() {
        stopOutgoingPlayer()

        let previousPlayer = player
        guard previousPlayer.currentItem != nil,
              previousPlayer.timeControlStatus == .playing,
              previousPlayer.volume > 0.001 else { return }

        let incomingPlayer = AVPlayer()
        incomingPlayer.automaticallyWaitsToMinimizeStalling = true
        timeControlObservation = nil
        player = incomingPlayer
        observePlaybackState(of: incomingPlayer)

        outgoingPlayer = previousPlayer
        let startingVolume = previousPlayer.volume
        let steps = volumeFadeSteps
        let stepDuration = volumeFadeStep

        outgoingFadeTask = Task { [weak self, previousPlayer] in
            guard let self else { return }
            for step in 1...steps {
                do {
                    try await Task.sleep(for: stepDuration)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                previousPlayer.volume = StationSwitchFadePolicy.volume(
                    startingVolume: startingVolume,
                    step: step,
                    steps: steps
                )
            }

            previousPlayer.volume = 0
            previousPlayer.pause()
            previousPlayer.replaceCurrentItem(with: nil)
            if self.outgoingPlayer === previousPlayer {
                self.outgoingPlayer = nil
                self.outgoingFadeTask = nil
            }
        }
    }

    private func handleMediaServicesReset() {
        Log.playback.error("Media services were reset; rebuilding the player")
        stopOutgoingPlayer()
        let station = currentStation
        let wasActive = intendsToPlay || isPlaying || isBuffering || isReconnecting

        playbackRequestID &+= 1
        resumeAfterInterruption = false
        reconnectTask?.cancel()
        reconnectTask = nil
        stalledPlaybackTask?.cancel()
        stalledPlaybackTask = nil
        volumeFadeTask?.cancel()
        volumeFadeTask = nil
        itemStatusObservation = nil
        timeControlObservation = nil
        removeItemNotificationObservers()
        metadataOutput = nil
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
        }
    }

    private func handleInterruption(_ type: AVAudioSession.InterruptionType, shouldResume: Bool) {
        switch type {
        case .began:
            // Read intent, not UI state: iOS has already paused AVPlayer and the KVO update may have won the race.
            let wasActive = intendsToPlay || isPlaying || isBuffering || isReconnecting
            suspendForInterruption()
            resumeAfterInterruption = wasActive
        case .ended:
            let shouldRestart = resumeAfterInterruption && shouldResume
            resumeAfterInterruption = false
            if shouldRestart {
                resume()
            } else {
                scheduleAudioSessionDeactivation()
            }
        @unknown default:
            break
        }
    }

    // Release the stream but leave the audio session alone; deactivating it mid-interruption can
    // cost us the shouldResume hint and the Now Playing registration.
    private func suspendForInterruption() {
        playbackRequestID &+= 1
        intendsToPlay = false
        stopOutgoingPlayer()
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectFailures = 0
        shouldFadeInWhenPlaybackStarts = false
        volumeFadeTask?.cancel()
        volumeFadeTask = nil
        player.volume = 0
        player.pause()
        player.replaceCurrentItem(with: nil)
        itemStatusObservation = nil
        removeItemNotificationObservers()
        metadataOutput = nil
        isReconnecting = false
        isPlaying = false
        isBuffering = false
        playbackError = false
    }

    private func pauseAfterRouteLoss() {
        guard isPlaying || isBuffering else { return }
        pause()
    }

    // AVPlayer status is the source of truth for the current item's playback state.
    private func updatePlaybackState() {
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
        intendsToPlay = true
        beginPlayback(station, useHQ: useHQ, preservingReconnectState: false)
    }

    // Every new request supersedes previous observers, fades, and reconnect attempts via a fresh request ID.
    private func beginPlayback(
        _ station: RadioStation,
        useHQ: Bool,
        preservingReconnectState: Bool
    ) {
        if !preservingReconnectState {
            reconnectTask?.cancel()
            reconnectTask = nil
            isReconnecting = false

            reconnectFailures = 0
        }

        stalledPlaybackTask?.cancel()
        stalledPlaybackTask = nil
        playbackRequestID &+= 1
        let requestID = playbackRequestID
        useHQForCurrentStation = useHQ
        volumeFadeTask?.cancel()
        volumeFadeTask = nil
        shouldFadeInWhenPlaybackStarts = false

        guard let url = station.streamURL(useHQ: useHQ) else {
            stopOutgoingPlayer()
            player.volume = 0
            player.pause()
            player.replaceCurrentItem(with: nil)
            itemStatusObservation = nil
            removeItemNotificationObservers()
            metadataOutput = nil
            deactivateAudioSession()
            currentStation = station
        stationArtworkData = nil
            loadArtwork(for: station)
            metadata = nil
            isPlaying = false
            isBuffering = false
            playbackError = true
            isReconnecting = true
            recordReconnectFailure()
            scheduleReconnect(for: station, useHQ: useHQ, requestID: requestID)
            return
        }

        // Start the replacement immediately; the previous player fades independently.
        // A pending handoff never needs to wait for a fade task before starting audio.
        prepareForStationSwitch()
        startPlayback(station, url: url, useHQ: useHQ, requestID: requestID)
    }

    // Retry the same station with bounded backoff, but only while this request is still the active one.
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
        recordReconnectFailure()
        scheduleReconnect(for: station, useHQ: useHQ, requestID: requestID)
    }

    private func recordReconnectFailure() {
        reconnectFailures += 1
        if reconnectFailures == backgroundReconnectFailureLimit {
            onPlaybackActivityChange?()
        }
    }

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

        reconnectFailures = 0
        beginPlayback(
            station,
            useHQ: useHQForCurrentStation,
            preservingReconnectState: true
        )
    }

    private func activateAudioSession() -> Bool {
        sessionDeactivationTask?.cancel()
        sessionDeactivationTask = nil
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

    private func scheduleAudioSessionDeactivation() {
        // Keep the session for a while after a pause so the system still lists us as the Now Playing app.
        // A later Play command reactivates it immediately before starting AVPlayer.
        sessionDeactivationTask?.cancel()
        sessionDeactivationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: self.pausedSessionLinger)
            } catch {
                return
            }
            guard !Task.isCancelled, !self.hasActivePlayback else { return }
            self.sessionDeactivationTask = nil
            self.deactivateAudioSession()
        }
    }

    private func deactivateAudioSession() {
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

    // Build a fresh AVPlayerItem and attach status/metadata observers before starting the stream.
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
            stationArtworkData = nil
        currentStation = station
        loadArtwork(for: station)
        metadata = nil
        playbackError = false
        isBuffering = true
        isPlaying = false

        player.volume = 0
        player.pause()
        player.replaceCurrentItem(with: nil)

        guard activateAudioSession() else {
            deactivateAudioSession()
                    isPlaying = false
            isBuffering = false
            playbackError = true
            isReconnecting = true
            recordReconnectFailure()
            scheduleReconnect(for: station, useHQ: useHQ, requestID: requestID)
            return
        }

        let item = AVPlayerItem(url: url)
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

                    if self.playbackRequestID == requestID {
                        self.updatePlaybackState()
                    }
                    self.fadeInWhenReady(observedItem, requestID: requestID)
                }
            }
        }

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
        player.volume = startupPlaybackVolume
        shouldFadeInWhenPlaybackStarts = true

        player.replaceCurrentItem(with: item)
        player.play()
        // Startup watchdog: a stream that connects but never delivers audio never fails or stalls on its own.
        scheduleStalledPlaybackRecovery(for: station, useHQ: useHQ, requestID: requestID, item: item)
        updateNowPlayingForCurrentOS()
    }

    // Fade out before releasing the current item so pausing does not click or pop.
    func pause() {
        intendsToPlay = false
        playbackRequestID &+= 1
        let requestID = playbackRequestID
        resumeAfterInterruption = false
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

    // Return false when cancelled or superseded so an obsolete fade cannot change the new stream's volume.
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
        intendsToPlay = false
        playbackRequestID &+= 1
        stopOutgoingPlayer()
        resumeAfterInterruption = false
        reconnectTask?.cancel()
        reconnectTask = nil
        isReconnecting = false
        reconnectFailures = 0
            stationArtworkData = nil
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
        clearNowPlayingForCurrentOS()
        isPlaying = false
        isBuffering = false
        playbackError = false
        deactivateAudioSession()
    }

    nonisolated func metadataOutput(
        _ output: AVPlayerItemMetadataOutput,
        didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup],
        from track: AVPlayerItemTrack?
    ) {

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

        guard let current = metadataOutput, ObjectIdentifier(current) == source else { return }
        metadata = title
    }

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
