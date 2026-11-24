import Foundation
import AVFoundation
import NowPlaying
import Observation
import os

/// Main-actor owner of AVPlayer, audio-session lifecycle, stream metadata, and automatic recovery.
/// `playbackRequestID` invalidates callbacks and tasks that belong to an older station request.
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
    private(set) var isBuffering = false {
        didSet {
            if oldValue != isBuffering {
                onPlaybackActivityChange?()
            }
        }
    }
    private(set) var playbackError = false
    private(set) var isReconnecting = false {
        didSet {
            if oldValue != isReconnecting {
                onPlaybackActivityChange?()
            }
        }
    }
    private(set) var metadata: String?

    var hasActivePlayback: Bool {
        isPlaying || isBuffering || isReconnecting
    }

    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onPlaybackActivityChange: (() -> Void)?

    @ObservationIgnored private var player = AVPlayer()
    private var volumeFadeTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var stalledPlaybackTask: Task<Void, Never>?
    private var itemNotificationObservers: [NSObjectProtocol] = []
    private var playbackRequestID: UInt64 = 0
    private var shouldFadeInWhenPlaybackStarts = false

    private var holdsSwitchUI = false
    private var switchTargetItem: AVPlayerItem?

    private let volumeFadeSteps = 24
    private let volumeFadeStep: Duration = .milliseconds(25)

    private let reconnectBaseDelay: TimeInterval = 3
    private let reconnectMaxDelay: TimeInterval = 30
    private var reconnectFailures = 0
    private let stalledPlaybackRecoveryDelay: Duration = .seconds(10)

    private var resumeAfterInterruption = false
    private var routeChangeObserver: NSObjectProtocol?
    private var timeControlObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?
    private var metadataOutput: AVPlayerItemMetadataOutput?
    var stationArtworkData: Data?
    var nowPlayingSession: MediaSession<RadioAudioPlayer>?
    private var interruptionObserver: NSObjectProtocol?
    private var audioSessionIsActive = false
    private var useHQForCurrentStation = true
    private var mediaServicesResetObserver: NSObjectProtocol?


    var hasMultipleStations = false

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

        timeControlObservation = Self.observeTimeControlStatus(of: player) { [weak self] in
            Task { @MainActor in
                self?.updatePlaybackState()
            }
        }
    }

    private func handleMediaServicesReset() {
        Log.playback.error("Media services were reset; rebuilding the player")
        let station = currentStation
        let wasActive = isPlaying || isBuffering || isReconnecting

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
        }
    }

    private func handleInterruption(_ type: AVAudioSession.InterruptionType, shouldResume: Bool) {
        switch type {
        case .began:
            let wasActive = isPlaying || isBuffering || isReconnecting
            pause()

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

    // AVPlayer status is the source of truth; during a station switch, hold the UI on buffering until the new item plays.
    private func updatePlaybackState() {
        if holdsSwitchUI {

            if player.timeControlStatus == .playing,
               let target = switchTargetItem,
               player.currentItem === target,
               target.status == .readyToPlay {
                holdsSwitchUI = false
                switchTargetItem = nil
            } else {
                isPlaying = false
                isBuffering = true
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
        holdsSwitchUI = false
        switchTargetItem = nil
        useHQForCurrentStation = useHQ
        volumeFadeTask?.cancel()
        volumeFadeTask = nil
        shouldFadeInWhenPlaybackStarts = false

        guard let url = station.streamURL(useHQ: useHQ) else {

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
            reconnectFailures += 1
            scheduleReconnect(for: station, useHQ: useHQ, requestID: requestID)
            return
        }

        let hasAudibleStream = player.currentItem != nil && player.volume > 0.001

        guard hasAudibleStream else {
            startPlayback(station, url: url, useHQ: useHQ, requestID: requestID)
            return
        }

        holdsSwitchUI = true
        currentStation = station
            stationArtworkData = nil
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
        scheduleReconnect(for: station, useHQ: useHQ, requestID: requestID)
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
        // Release the nonmixable playback session as soon as playback is paused.
        // A later Play command reactivates it immediately before starting AVPlayer.
        deactivateAudioSession()
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
            holdsSwitchUI = false
            switchTargetItem = nil
            isPlaying = false
            isBuffering = false
            isReconnecting = false
            playbackError = true
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
        player.volume = 0
        shouldFadeInWhenPlaybackStarts = true

        player.replaceCurrentItem(with: item)
        player.play()
        activateNowPlayingSession()
    }

    // Fade out before releasing the current item so pauses and station changes do not click or pop.
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
        playbackRequestID &+= 1
        resumeAfterInterruption = false
        holdsSwitchUI = false
        switchTargetItem = nil
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
        nowPlayingSession = nil
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
