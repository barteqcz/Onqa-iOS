import Foundation
import CoreLocation
import MapKit
import os

enum LocationPresentation {
    static func isPending(
        source: LocationSource,
        permissionDenied: Bool,
        resolvingName: Bool,
        hasName: Bool,
        hasCoordinate: Bool
    ) -> Bool {
        guard !hasName else { return false }
        if resolvingName { return true }
        guard !permissionDenied else { return false }
        return source == .gps && !hasCoordinate
    }
}

enum LocationTrackingPolicy {
    /// Track while the app is visible or playback is active, including buffering
    /// and reconnecting. A separate grace period handles an intentional stop.
    static func shouldTrack(
        source: LocationSource,
        hasLocationAccess: Bool,
        appIsActive: Bool,
        hasActivePlayback: Bool
    ) -> Bool {
        guard source == .gps, hasLocationAccess else { return false }
        return appIsActive || hasActivePlayback
    }

    /// Preserve a background session until its scheduled stop grace period ends.
    static func shouldKeepTrackingDuringStopGrace(
        source: LocationSource,
        hasLocationAccess: Bool,
        hasBackgroundActivitySession: Bool,
        hasPendingStop: Bool
    ) -> Bool {
        source == .gps
            && hasLocationAccess
            && hasBackgroundActivitySession
            && hasPendingStop
    }
}

enum LocationRefreshPolicy {
    /// Reuse cached station results until movement reaches the refresh
    /// threshold. The location manager already filters by the same distance,
    /// but its first fix is always delivered and coarse fixes jitter, so the
    /// threshold is applied here as well.
    static func shouldReloadStations(
        from previousCoordinate: CLLocationCoordinate2D?,
        to coordinate: CLLocationCoordinate2D,
        thresholdKm: Double
    ) -> Bool {
        guard let previousCoordinate else { return true }
        return StationProcessor.hasMoved(
            atLeast: thresholdKm,
            from: previousCoordinate,
            to: coordinate
        )
    }
}
enum LocationFixQuality {
    /// Matches the Android app: fixes are accepted whatever their accuracy, so
    /// "Approximate Location" works as well as precise location (station
    /// coverage areas are tens of kilometres wide). Only an invalid fix, which
    /// Core Location marks with a negative accuracy, is dropped.
    static func isUsable(horizontalAccuracy: CLLocationAccuracy) -> Bool {
        horizontalAccuracy >= 0
    }
}

enum LocationNamePolicy {
    /// City-name lookups are retried (with backoff) even when the listener has
    /// not moved, but never in the background where nobody sees the name.
    static func shouldRetryLookup(
        hasName: Bool,
        isResolving: Bool,
        isRetryAllowed: Bool,
        appIsActive: Bool
    ) -> Bool {
        !hasName && !isResolving && isRetryAllowed && appIsActive
    }
}

enum LocationAgePolicy {
    /// Nothing is shown for a location confirmed less than a minute ago, so a
    /// fresh location has no extra text next to it.
    static let minimumAge: TimeInterval = 60

    /// A localized relative age such as "5 min. ago". It is in minutes up to an
    /// hour and in hours or days after that. Returns nil for a fresh location,
    /// a missing timestamp or one in the future (the clock was changed).
    static func text(since retrievedAt: Date?, now: Date = Date()) -> String? {
        guard let retrievedAt,
              now.timeIntervalSince(retrievedAt) >= minimumAge else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: retrievedAt, relativeTo: now)
    }
}

extension RadioStore {
    var hasLocationAccess: Bool {
        locationAuthorizationStatus == .authorizedWhenInUse
            || locationAuthorizationStatus == .authorizedAlways
    }

    var canEnterApp: Bool {
        // Permission is checked before Alright is enabled. Once the user
        // confirms, keep the app route stable for this session instead of
        // letting a transient Core Location status refresh undo the tap.
        hasConfirmedOnboardingThisSession
    }

    var needsLocationSettings: Bool {
        locationAuthorizationStatus == .denied
            || locationAuthorizationStatus == .restricted
    }

    /// A world globe is used until reverse geocoding can identify a country.
    var locationFlag: String {
        guard locationName != nil,
              let code = locationCountryCode,
              code.count == 2 else { return "🌍" }
        let scalars = code.uppercased().unicodeScalars.compactMap { UnicodeScalar(127397 + $0.value) }
        return scalars.count == 2 ? String(String.UnicodeScalarView(scalars)) : "🌍"
    }

    /// True while the location or its city name is still being retrieved; the
    /// header shows a native progress spinner instead of text then.
    var isLocationPending: Bool {
        let rawLocation = settings.locationSource == .manual
            ? (settings.manualCity ?? locationName)
            : locationName
        let hasName = rawLocation?
            .components(separatedBy: ",").first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false

        return LocationPresentation.isPending(
            source: settings.locationSource,
            permissionDenied: locationPermissionDenied,
            resolvingName: isResolvingLocationName,
            hasName: hasName,
            hasCoordinate: locationCoordinate != nil
        )
    }

    var locationLabel: String {
        let rawLocation = settings.locationSource == .manual
            ? (settings.manualCity ?? locationName)
            : locationName

        if let rawLocation {
            let city = rawLocation
                .components(separatedBy: ",")
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let city, !city.isEmpty {
                return city
            }
        }

        if !isLocationPending,
           locationCoordinate != nil || settings.locationSource == .manual || locationPermissionDenied {
            return String(localized: "Unknown location")
        }
        return String(localized: "Finding your location…")
    }

    /// The last successful city-geocoding time for the currently displayed
    /// name. GPS timestamps are stored with SavedLocation; manual timestamps
    /// are stored alongside the manually selected city in AppSettings.
    var displayedLocationRetrievedAt: Date? {
        if settings.locationSource == .manual {
            guard settings.manualCity != nil || locationName != nil else { return nil }
            return settings.manualLocationRetrievedAt
                ?? locationRetrievedAt
                ?? lastAutomaticLocationRetrievedAt
        }
        guard locationName != nil else { return nil }
        return locationRetrievedAt
    }

    /// How long ago the currently displayed city was successfully geocoded.
    func locationAgeText(now: Date = Date()) -> String? {
        LocationAgePolicy.text(since: displayedLocationRetrievedAt, now: now)
    }

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        refreshLocationAuthorizationStatus()
        guard canEnterApp else { return }
        // Covers the app being closed while Manual was selected with no location.
        revertToAutoIfManualLocationMissing()
        configureLocationUpdates()

        if settings.locationSource == .manual {
            loadManualCoordinate()
            await loadStations()
        } else if let coordinate = locationCoordinate {
            // The previous session's location was restored: show its stations
            // right away. The first live fix corrects the list if the person
            // has moved by at least the refresh threshold since then.
            await loadStations(at: coordinate)
        } else {
            // Start catalog preparation independently of GPS so the catalog
            // download card can appear while the header resolves the location.
            Task { _ = try? await ensureCatalogAvailable() }
        }
    }

    /// Applies the automatic location saved by the previous session. The
    /// header and station list can then be shown before the first fix arrives.
    /// The last-known values are always kept, so switching from Manual back to
    /// Auto restores them too; the live position is only set while Auto is
    /// active and location access still holds.
    func restoreLastAutomaticLocation(_ saved: SavedLocation) {
        lastAutomaticCoordinate = saved.coordinate
        lastAutomaticLocationName = saved.name
        lastAutomaticLocationCountryCode = saved.countryCode
        lastAutomaticLocationRetrievedAt = saved.retrievedAt

        guard settings.locationSource == .gps, hasConfirmedOnboardingThisSession else { return }
        locationCoordinate = saved.coordinate
        locationName = saved.name
        locationCountryCode = saved.countryCode
        locationRetrievedAt = saved.retrievedAt
    }

    /// Manual mode may be selected before the user picks a point. Only fall
    /// back to Auto when GPS access is available; never force a user who declined
    /// location access back into a mode they cannot use.
    func revertToAutoIfManualLocationMissing() {
        guard settings.locationSource == .manual,
              settings.manualLatitude == nil || settings.manualLongitude == nil,
              hasLocationAccess else { return }
        var value = settings
        value.locationSource = .gps
        settings = value
    }

    func refreshLocationAuthorizationStatus(configureTracking: Bool = true) {
        applyLocationAuthorizationStatus(
            authorizationProbe.authorizationStatus,
            configureTracking: configureTracking
        )
    }

    func applyLocationAuthorizationStatus(
        _ status: CLAuthorizationStatus,
        configureTracking: Bool = true
    ) {
        let previouslyHadLocationAccess = hasLocationAccess
        locationAuthorizationStatus = status
        locationPermissionDenied = status == .denied || status == .restricted

        if locationPermissionDenied,
           settings.onboardingCompleted,
           settings.locationSource == .gps {
            // If access is revoked in Settings, preserve app usability in Manual mode.
            applyLocationSource(.manual)
        }

        if isAutomaticLocationSelectionPending {
            if hasLocationAccess {
                isAutomaticLocationSelectionPending = false
                shouldShowLocationSettingsPrompt = false
                applyLocationSource(.gps)
            } else if needsLocationSettings {
                isAutomaticLocationSelectionPending = false
                shouldShowLocationSettingsPrompt = true
            }
        }

        if !previouslyHadLocationAccess,
           hasLocationAccess,
           hasConfirmedOnboardingThisSession,
           settings.locationSource == .manual {
            loadManualCoordinate()
            refreshStations()
        }

        if configureTracking {
            configureLocationUpdates()
        }
    }

    /// Selects Auto only after Core Location authorization is available.
    /// A first-time request uses the native permission prompt; a previous
    /// denial is handled with an in-app alert that can open iOS Settings.
    func selectLocationSource(_ source: LocationSource) {
        guard source == .gps else {
            isAutomaticLocationSelectionPending = false
            shouldShowLocationSettingsPrompt = false
            applyLocationSource(.manual)
            return
        }

        refreshLocationAuthorizationStatus()
        switch locationAuthorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            isAutomaticLocationSelectionPending = false
            shouldShowLocationSettingsPrompt = false
            applyLocationSource(.gps)
        case .notDetermined:
            isAutomaticLocationSelectionPending = true
            ensureLocationServiceSession()
        case .denied, .restricted:
            isAutomaticLocationSelectionPending = true
            shouldShowLocationSettingsPrompt = true
        @unknown default:
            isAutomaticLocationSelectionPending = false
            shouldShowLocationSettingsPrompt = true
        }
    }

    func cancelPendingLocationSourceSelection() {
        isAutomaticLocationSelectionPending = false
        shouldShowLocationSettingsPrompt = false
    }

    func applyLocationSource(_ source: LocationSource) {
        guard settings.locationSource != source else { return }
        var value = settings
        value.locationSource = source
        settings = value
    }

    /// Triggers the system permission prompt on first use. After a denial the
    /// prompt cannot be shown again; the onboarding location card opens the
    /// app's Settings page instead.
    func requestLocationAccess() {
        refreshLocationAuthorizationStatus()
        if locationAuthorizationStatus == .notDetermined {
            ensureLocationServiceSession()
        }
    }

    func prepareManualOnboarding() {
        var value = settings
        value.locationSource = .manual
        settings = value
        hasConfirmedOnboardingThisSession = false
    }

    func completeOnboarding(usingManualLocation: Bool = false) {
        var value = settings
        if usingManualLocation {
            value.locationSource = .manual
        }
        value.onboardingCompleted = true
        settings = value
        hasConfirmedOnboardingThisSession = true
        configureLocationUpdates()

        if settings.locationSource == .manual {
            loadManualCoordinate()
            Task { await loadStations() }
        } else {
            // Begin the catalog download independently of the live location stream.
            Task { _ = try? await ensureCatalogAvailable() }
            // The live location stream starts when the user confirms Auto.
        }
    }

    /// A fix from the location manager. A fix can only arrive with access, but
    /// the cached status may lag behind it, so refresh the status first.
    func handleLocationManagerFix(_ location: CLLocation) {
        if !hasLocationAccess {
            refreshLocationAuthorizationStatus(configureTracking: false)
        }
        handleLocationFix(location)
    }

    /// The location manager reports the current status as soon as it starts and
    /// again whenever the person changes it. Starting tracking after a grant is
    /// the job of the service session diagnostics, so only a loss of access
    /// needs to reconfigure tracking here.
    func handleLocationAuthorizationChange(_ status: CLAuthorizationStatus) {
        let lostAccess = status == .denied || status == .restricted
        applyLocationAuthorizationStatus(status, configureTracking: lostAccess)
    }

    private var hasResolvedLocationName: Bool {
        let currentName = settings.locationSource == .manual
            ? (settings.manualCity ?? locationName)
            : locationName
        return currentName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
    }

    func handleLocationFix(_ location: CLLocation) {
        guard settings.locationSource == .gps else { return }
        guard LocationFixQuality.isUsable(horizontalAccuracy: location.horizontalAccuracy) else { return }

        let hasLocationName = hasResolvedLocationName
        let movedEnough = StationProcessor.shouldProcessLocationUpdate(
            from: locationCoordinate,
            to: location.coordinate,
            thresholdKm: Self.locationRefreshThresholdKm
        )
        guard movedEnough else {
            let nameIsCurrent = hasLocationName
                && !isLocationNameOutdated
                && !isLocationNameStale
            // No station or coordinate change, but a failed city lookup must
            // not stay failed until the next kilometre of movement.
            if LocationNamePolicy.shouldRetryLookup(
                hasName: nameIsCurrent,
                isResolving: isResolvingLocationName,
                isRetryAllowed: isNameLookupRetryAllowed,
                appIsActive: isAppActive
            ) {
                refreshLocationName(
                    for: location,
                    saveManualCity: false,
                    keepsCurrentName: hasLocationName
                )
            }
            return
        }

        locationPermissionDenied = false
        locationCoordinate = location.coordinate
        lastAutomaticCoordinate = location.coordinate
        if isAppActive {
            // Keep showing the current city while the next one resolves, so the
            // header does not flip to a spinner at every 1 km of driving.
            refreshLocationName(
                for: location,
                saveManualCity: false,
                keepsCurrentName: hasLocationName
            )
        } else {
            // Nobody sees the name in the background; skip the network and
            // geocoder rate limit, and refresh when the app is visible again.
            isLocationNameStale = true
        }
        if movedEnough,
           hasConfirmedOnboardingThisSession,
           settings.locationSource == .gps {
            Task { await loadStations(at: location.coordinate) }
        }
    }

    /// Refreshes the city name after the app returns to the foreground if it
    /// was skipped in the background or a previous lookup failed.
    func refreshLocationNameIfNeeded() {
        guard hasConfirmedOnboardingThisSession,
              !isResolvingLocationName,
              let coordinate = locationCoordinate else { return }
        let hasName = hasResolvedLocationName
        let needsLookup = isLocationNameStale
            || LocationNamePolicy.shouldRetryLookup(
                hasName: hasName && !isLocationNameOutdated,
                isResolving: isResolvingLocationName,
                isRetryAllowed: isNameLookupRetryAllowed,
                appIsActive: isAppActive
            )
        guard needsLookup else { return }
        refreshLocationName(
            for: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude),
            saveManualCity: settings.locationSource == .manual,
            keepsCurrentName: hasName
        )
    }

    /// Retry the current city's lookup immediately after connectivity returns.
    /// The last successful name and timestamp remain visible while it retries.
    func retryLocationNameAfterReconnect() {
        resetNameLookupBackoff()
        guard hasConfirmedOnboardingThisSession, locationCoordinate != nil else { return }
        locationLookupID &+= 1
        cancelReverseGeocoding()
        isResolvingLocationName = false
        isLocationNameStale = true
        refreshLocationNameIfNeeded()
    }

    func handleLocationUpdateFailure(_ error: Error) {
        let code = (error as? CLError)?.code
        if let code, LocationErrorPolicy.action(for: code) == .keepTrying {
            // "Location unknown" and network hiccups are transient: the
            // manager keeps trying and delivers a fix when it has one.
            return
        }
        Log.location.error("Location updates failed: \(error.localizedDescription, privacy: .public)")
        // The manager has stopped delivering. Drop it so the next
        // configureLocationUpdates() starts a fresh one.
        stopLocationUpdates()
        refreshLocationAuthorizationStatus(configureTracking: false)
        if settings.locationSource == .gps && !hasLocationAccess {
            locationName = nil
            locationCountryCode = nil
            locationRetrievedAt = nil
        }
    }

    func setAppIsActive(_ isActive: Bool) {
        isAppActive = isActive
        // Refresh permission after returning from iOS Settings, and update
        // background tracking when the app enters or leaves the foreground.
        refreshLocationAuthorizationStatus(configureTracking: false)
        configureLocationUpdates()
        if isActive {
            refreshLocationNameIfNeeded()
        }
    }

    /// Keep the background location session briefly after playback actually stops,
    /// allowing a quick resume without tearing down and recreating Core Location.
    private static let locationStopGracePeriod: Duration = .seconds(8)

    func configureLocationUpdates() {
        guard settings.locationSource == .gps else {
            cancelPendingLocationStop()
            stopLocationUpdates()
            endBackgroundActivitySession()
            endLocationServiceSession()
            return
        }

        // Start the grace period as soon as all playback activity ends, even if
        // the app is already in the background. This keeps location alive for
        // the full grace period after a user pause/stop.
        if !player.hasActivePlayback, backgroundActivitySession != nil {
            scheduleLocationStop()
        }

        let shouldKeepTrackingDuringGrace = LocationTrackingPolicy.shouldKeepTrackingDuringStopGrace(
            source: settings.locationSource,
            hasLocationAccess: hasLocationAccess,
            hasBackgroundActivitySession: backgroundActivitySession != nil,
            hasPendingStop: locationStopTask != nil
        )

        if shouldTrackLocation || shouldKeepTrackingDuringGrace {
            ensureLocationServiceSession()
            if player.hasActivePlayback {
                cancelPendingLocationStop()
                // Create while foregrounded so When In Use authorization can continue
                // delivering location events after the app enters the background.
                if backgroundActivitySession == nil {
                    backgroundActivitySession = CLBackgroundActivitySession()
                }
            }
            startLocationUpdates()
        } else {
            // Not tracking (e.g. in the background with nothing playing, or
            // no access). Tear down immediately: a suspended app must never
            // be left holding a location session, or iOS can keep showing
            // the blue indicator for it.
            cancelPendingLocationStop()
            stopLocationUpdates()
            endBackgroundActivitySession()
        }
    }

    private var shouldTrackLocation: Bool {
        hasConfirmedOnboardingThisSession
            && LocationTrackingPolicy.shouldTrack(
                source: settings.locationSource,
                hasLocationAccess: hasLocationAccess,
                appIsActive: isAppActive,
                hasActivePlayback: player.hasActivePlayback
            )
    }

    private func scheduleLocationStop() {
        // Keep the earliest deadline; repeated calls must not push it back.
        guard locationStopTask == nil else { return }
        locationStopTask = Task { [weak self] in
            try? await Task.sleep(for: Self.locationStopGracePeriod)
            guard !Task.isCancelled, let self else { return }
            self.locationStopTask = nil
            // Re-evaluate: state may have changed during the grace period.
            if !self.shouldTrackLocation {
                self.stopLocationUpdates()
            }
            if !self.player.hasActivePlayback {
                self.endBackgroundActivitySession()
            }
        }
    }

    private func cancelPendingLocationStop() {
        locationStopTask?.cancel()
        locationStopTask = nil
    }

    func ensureLocationServiceSession() {
        guard locationServiceSession == nil else { return }
        let session = CLServiceSession(authorization: .whenInUse)
        locationServiceSession = session

        locationServiceDiagnosticsTask = Task { [weak self, session] in
            do {
                for try await diagnostic in session.diagnostics {
                    guard let self, !Task.isCancelled else { break }
                    if diagnostic.authorizationDenied || diagnostic.authorizationDeniedGlobally {
                        self.applyLocationAuthorizationStatus(.denied)
                    } else if diagnostic.authorizationRestricted {
                        self.applyLocationAuthorizationStatus(.restricted)
                    } else if diagnostic.authorizationRequestInProgress {
                        self.applyLocationAuthorizationStatus(.notDetermined, configureTracking: false)
                    } else {
                        self.refreshLocationAuthorizationStatus()
                    }
                }
            } catch is CancellationError {
                // Expected when switching to Manual mode.
            } catch {
                Log.location.error("Location authorization diagnostics failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func endLocationServiceSession() {
        locationServiceDiagnosticsTask?.cancel()
        locationServiceDiagnosticsTask = nil
        locationServiceSession?.invalidate()
        locationServiceSession = nil
    }

    func startLocationUpdates() {
        guard locationUpdateSource == nil else { return }
        // Station coverage areas are tens of kilometres wide, and the app only
        // refreshes station results after roughly 1 km of movement. Request a
        // coarse fix and use a distance filter to reduce unnecessary wakeups.
        // Core Location chooses the positioning technologies; this configuration
        // does not guarantee that GPS stays off during a drive.
        let source = LocationUpdateSource()
        source.onFix = { [weak self] location in
            self?.handleLocationManagerFix(location)
        }
        source.onAuthorizationChange = { [weak self] status in
            self?.handleLocationAuthorizationChange(status)
        }
        source.onFailure = { [weak self] error in
            self?.handleLocationUpdateFailure(error)
        }
        locationUpdateSource = source
        source.start()
    }

    func stopLocationUpdates() {
        locationUpdateSource?.stop()
        locationUpdateSource = nil
    }

    func endBackgroundActivitySession() {
        backgroundActivitySession?.invalidate()
        backgroundActivitySession = nil
    }

    /// Port of the Android StationCoverageManager: keep playing the current station from the nearest
    /// transmitter in coverage, otherwise fall back to the same network, a favorite, or the nearest
    /// station, and stop if nothing is in range.
    func checkCoverageAndSwitch() {
        // A location refresh can finish while a newly selected stream is still
        // preparing or reconnecting. Do not replace or stop AVPlayer during
        // that transition; transmitter switching resumes after playback is
        // stable and a subsequent accepted location update arrives.
        guard player.isPlaying,
              !player.isReconnecting,
              let current = player.currentStation,
              let currentURL = player.currentStreamURL else { return }
        let useHQ = settings.useHQStream

        func inCoverage(_ station: RadioStation) -> Bool {
            guard let distance = station.distanceKm, let coverage = station.coverageKm else { return false }
            return distance <= coverage
        }
        func nearest(_ list: [RadioStation]) -> RadioStation? {
            list.min { ($0.distanceKm ?? .greatestFiniteMagnitude) < ($1.distanceKm ?? .greatestFiniteMagnitude) }
        }
        func normalized(_ url: URL) -> String {
            url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        let currentKey = normalized(currentURL)

        let sameIdentity = catalogStations.filter { $0.id == current.id }
        let matching = sameIdentity.isEmpty
            ? catalogStations.filter { $0.matches(url: currentURL) }
            : sameIdentity
        if let match = nearest(matching.filter(inCoverage)) {
            if let target = match.streamURL(useHQ: useHQ), normalized(target) != currentKey {
                player.play(match, useHQ: useHQ)
            }
            return
        }

        let network = current.network ?? matching.first?.network
        let candidates = StationProcessor.groupAndSort(catalogStations, favorites: favorites).filter(inCoverage)
        var fallback: RadioStation?
        if let network {
            fallback = nearest(candidates.filter { $0.network == network })
        }
        if fallback == nil { fallback = nearest(candidates.filter { $0.isFavorite }) }
        if fallback == nil { fallback = nearest(candidates) }

        if let fallback {
            if let target = fallback.streamURL(useHQ: useHQ), normalized(target) != currentKey {
                player.play(fallback, useHQ: useHQ)
            }
        } else {
            player.stop()
        }
    }

    func setManualLocation(
        _ coordinate: CLLocationCoordinate2D,
        completesOnboarding: Bool = false
    ) {
        let wasAlreadyManual = settings.locationSource == .manual
        var value = settings
        value.locationSource = .manual
        value.manualLatitude = coordinate.latitude
        value.manualLongitude = coordinate.longitude
        // Keep the last successful city visible until this point is resolved.
        if completesOnboarding {
            value.onboardingCompleted = true
        }
        settings = value
        locationCoordinate = coordinate

        if completesOnboarding {
            hasConfirmedOnboardingThisSession = true
            configureLocationUpdates()
        }

        if wasAlreadyManual {
            refreshLocationName(
                for: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude),
                saveManualCity: true,
                keepsCurrentName: hasResolvedLocationName
            )
            Task { await loadStations(at: coordinate) }
        }
    }
    func loadManualCoordinate() {
        guard let latitude = settings.manualLatitude, let longitude = settings.manualLongitude else {
            locationCoordinate = nil
            // Keep the last successful city available while the person is
            // choosing a manual point; no GPS/location retrieval is changed.
            if settings.manualCity == nil {
                locationName = lastAutomaticLocationName
                locationCountryCode = lastAutomaticLocationCountryCode
                locationRetrievedAt = lastAutomaticLocationRetrievedAt
            }
            return
        }

        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        locationCoordinate = coordinate
        if settings.manualCity == nil && locationName == nil {
            locationName = lastAutomaticLocationName
            locationCountryCode = lastAutomaticLocationCountryCode
            locationRetrievedAt = lastAutomaticLocationRetrievedAt
        }
        refreshLocationName(
            for: CLLocation(latitude: latitude, longitude: longitude),
            saveManualCity: true,
            keepsCurrentName: hasResolvedLocationName
        )
    }

    func effectiveCoordinate() -> CLLocationCoordinate2D? {
        if settings.locationSource == .manual,
           let latitude = settings.manualLatitude,
           let longitude = settings.manualLongitude {
            return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
        return locationCoordinate
    }

    func cancelReverseGeocoding() {
        reverseGeocodingTask?.cancel()
        reverseGeocodingTask = nil
        reverseGeocodingRequest?.cancel()
        reverseGeocodingRequest = nil
    }

    /// A lookup that fails (offline, or no city at that point) is retried with
    /// exponential backoff rather than on every location update.
    var isNameLookupRetryAllowed: Bool {
        guard let next = nextNameLookupDate else { return true }
        return Date() >= next
    }

    private func recordNameLookupFailure() {
        nameLookupFailures += 1
        let delay = RetryBackoff.delay(
            afterFailures: nameLookupFailures,
            base: 5,
            cap: 300
        )
        nextNameLookupDate = Date().addingTimeInterval(delay)
    }

    private func resetNameLookupBackoff() {
        nameLookupFailures = 0
        nextNameLookupDate = nil
    }

    func refreshLocationName(
        for location: CLLocation,
        saveManualCity: Bool,
        keepsCurrentName: Bool = false
    ) {
        locationLookupID &+= 1
        let requestID = locationLookupID
        if !keepsCurrentName {
            locationName = nil
            locationCountryCode = nil
        }
        isResolvingLocationName = true
        isLocationNameStale = false
        cancelReverseGeocoding()

        reverseGeocodingTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.reverseGeocode(location)
            guard !Task.isCancelled, requestID == self.locationLookupID else { return }
            // Both automatic and map-selected city lookups retain the last
            // successful name/time on failure and retry after backoff.
            if result.name == nil {
                self.recordNameLookupFailure()
            } else {
                self.resetNameLookupBackoff()
            }
            let keepsLastKnownName = result.name == nil
                && keepsCurrentName
                && self.hasResolvedLocationName
            let retrievedAt = Date()
            if keepsLastKnownName {
                self.isLocationNameOutdated = true
            } else {
                self.isLocationNameOutdated = false
                self.locationName = result.name
                self.locationCountryCode = result.countryCode
                self.locationRetrievedAt = result.name == nil ? nil : retrievedAt
            }
            self.isResolvingLocationName = false
            self.reverseGeocodingTask = nil
            if self.settings.locationSource == .gps, !keepsLastKnownName {
                self.lastAutomaticLocationName = result.name
                self.lastAutomaticLocationCountryCode = result.countryCode
                self.lastAutomaticLocationRetrievedAt = self.locationRetrievedAt
                if !saveManualCity, let name = result.name {
                    // Saved together with the position this name was resolved
                    // for, so the pair never goes out of sync.
                    SavedLocationStorage.save(SavedLocation(
                        coordinate: location.coordinate,
                        name: name,
                        countryCode: result.countryCode,
                        retrievedAt: retrievedAt
                    ))
                }
            }
            if saveManualCity, let name = result.name {
                var value = self.settings
                value.manualCity = name
                value.manualLocationRetrievedAt = retrievedAt
                self.settings = value
            }
        }
    }

    func reverseGeocode(_ location: CLLocation) async -> (name: String?, countryCode: String?) {
        guard let request = MKReverseGeocodingRequest(location: location) else {
            return (nil, nil)
        }
        reverseGeocodingRequest = request
        defer {
            if reverseGeocodingRequest === request {
                reverseGeocodingRequest = nil
            }
        }
        do {
            let mapItems = try await request.mapItems
            try Task.checkCancellation()
            guard let address = mapItems.first?.addressRepresentations,
                  let candidate = address.cityName ?? address.regionName else {
                return (nil, nil)
            }
            let name = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return (nil, nil) }
            return (name, address.region?.identifier)
        } catch is CancellationError {
            return (nil, nil)
        } catch {
            Log.location.error("Reverse geocoding failed: \(error.localizedDescription, privacy: .public)")
            return (nil, nil)
        }
    }
}
