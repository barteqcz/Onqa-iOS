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

// Keep tracking decisions as pure rules so app lifecycle and playback behavior can be tested independently.
enum LocationTrackingPolicy {

    static func shouldTrack(
        source: LocationSource,
        hasLocationAccess: Bool,
        appIsActive: Bool,
        hasActivePlayback: Bool
    ) -> Bool {
        guard source == .gps, hasLocationAccess else { return false }
        return appIsActive || hasActivePlayback
    }

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
    static let maximumLocationAge: TimeInterval = 30
    static let allowedFutureTimestampSkew: TimeInterval = 5
    static let maximumAccuracyMeters: CLLocationAccuracy =
        LocationRequestConfiguration.minimumDistance / 2

    // Keep uncertainty within 10% of the smallest currently relevant transmitter radius,
    // while never exceeding half of the 1 km movement threshold.
    static func maximumHorizontalAccuracy(nearbyCoverageKm: Double?) -> CLLocationAccuracy {
        guard let nearbyCoverageKm,
              nearbyCoverageKm.isFinite,
              nearbyCoverageKm > 0 else {
            return maximumAccuracyMeters
        }
        let coverageBasedLimit = max(100, nearbyCoverageKm * 100)
        return min(maximumAccuracyMeters, coverageBasedLimit)
    }

    static func isUsable(
        _ location: CLLocation,
        nearbyCoverageKm: Double?,
        now: Date = .now
    ) -> Bool {
        let accuracy = location.horizontalAccuracy
        let age = now.timeIntervalSince(location.timestamp)

        return CLLocationCoordinate2DIsValid(location.coordinate)
            && accuracy.isFinite
            && accuracy >= 0
            && accuracy <= maximumHorizontalAccuracy(nearbyCoverageKm: nearbyCoverageKm)
            && age.isFinite
            && age >= -allowedFutureTimestampSkew
            && age <= maximumLocationAge
    }
}

enum LocationNamePolicy {

    static func shouldRetryLookup(
        hasName: Bool,
        isResolving: Bool,
        isRetryAllowed: Bool,
        appIsActive: Bool
    ) -> Bool {
        !hasName && !isResolving && isRetryAllowed && appIsActive
    }

    static func shouldDisplayAge(hasName: Bool, hasFailedGeocode: Bool) -> Bool {
        hasName && hasFailedGeocode
    }

    static func hasFreshGeocode(
        hasName: Bool,
        retrievedAt: Date?,
        now: Date = Date()
    ) -> Bool {
        guard hasName, let retrievedAt else { return false }
        let age = now.timeIntervalSince(retrievedAt)
        return age >= 0 && age < LocationAgePolicy.minimumAge
    }
}

struct LocationNameRetryState: Equatable {
    var failureCount = 0
    var nextRetryAt: Date?
    var isNameOutdated = false
    var isStale = false

    func isRetryAllowed(at now: Date = Date()) -> Bool {
        guard let nextRetryAt else { return true }
        return now >= nextRetryAt
    }

    mutating func recordFailure(at now: Date = Date()) {
        if failureCount < Int.max { failureCount += 1 }
        let delay = RetryBackoff.delay(afterFailures: failureCount, base: 5, cap: 300)
        nextRetryAt = now.addingTimeInterval(delay)
    }

    mutating func resetBackoff() {
        failureCount = 0
        nextRetryAt = nil
    }
}

enum LocationAgePolicy {

    static let minimumAge: TimeInterval = 60

    static func text(since retrievedAt: Date?, now: Date = Date()) -> String? {
        guard let retrievedAt,
              now.timeIntervalSince(retrievedAt) >= minimumAge else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: retrievedAt, relativeTo: now)
    }
}

// Bridges Core Location, reverse geocoding, and manual/GPS selection into the app's observable state.
extension RadioStore {
    var hasLocationAccess: Bool {
        locationAuthorizationStatus == .authorizedWhenInUse
            || locationAuthorizationStatus == .authorizedAlways
    }

    var canEnterApp: Bool {

        hasConfirmedOnboardingThisSession
    }

    var needsLocationSettings: Bool {
        locationAuthorizationStatus == .denied
            || locationAuthorizationStatus == .restricted
    }

    var locationFlag: String {
        let rawLocation = settings.locationSource == .manual
            ? (settings.manualCity ?? locationName)
            : locationName
        let countryCode = settings.locationSource == .manual
            ? (settings.manualCountryCode ?? (settings.manualCity == nil ? locationCountryCode : nil))
            : locationCountryCode
        guard rawLocation != nil,
              let code = countryCode,
              code.count == 2 else { return "🌍" }
        let scalars = code.uppercased().unicodeScalars.compactMap { UnicodeScalar(127397 + $0.value) }
        return scalars.count == 2 ? String(String.UnicodeScalarView(scalars)) : "🌍"
    }

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

    var displayedLocationRetrievedAt: Date? {
        guard LocationNamePolicy.shouldDisplayAge(
            hasName: hasResolvedLocationName,
            hasFailedGeocode: isLocationNameOutdated
        ) else { return nil }

        if settings.locationSource == .manual {
            if settings.manualCity != nil {
                return settings.manualCityGeocodedAt
            }
            guard locationName != nil else { return nil }
            return locationRetrievedAt ?? lastAutomaticLocationRetrievedAt
        }
        guard locationName != nil else { return nil }
        return locationRetrievedAt
    }

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        refreshLocationAuthorizationStatus()
        guard canEnterApp else { return }

        revertToAutoIfManualLocationMissing()
        configureLocationUpdates()

        if settings.locationSource == .manual {
            loadManualCoordinate()
            await loadStations()
        } else if let coordinate = locationCoordinate {

            refreshLocationNameIfNeeded()
            await loadStations(at: coordinate)
        } else {

            Task { _ = try? await ensureCatalogAvailable() }
        }
    }

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

            Task { _ = try? await ensureCatalogAvailable() }

        }
    }

    func handleLocationManagerFix(_ location: CLLocation) {
        if !hasLocationAccess {
            refreshLocationAuthorizationStatus(configureTracking: false)
        }
        handleLocationFix(location)
    }

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

    // Ignore unusable or insignificant fixes; station refreshes and city-name lookups have separate lifecycles.
    func handleLocationFix(_ location: CLLocation) {
        guard settings.locationSource == .gps else { return }

        let smallestNearbyCoverage = stations.compactMap(\.coverageKm)
            .filter { $0.isFinite && $0 > 0 }
            .min()
        guard LocationFixQuality.isUsable(
            location,
            nearbyCoverageKm: smallestNearbyCoverage
        ) else { return }

        let hasLocationName = hasResolvedLocationName
        let movedEnough = StationProcessor.shouldProcessLocationUpdate(
            from: locationCoordinate,
            to: location.coordinate,
            thresholdKm: Self.locationRefreshThresholdKm
        )
        guard movedEnough else {
            let hasFreshGeocode = LocationNamePolicy.hasFreshGeocode(
                hasName: hasLocationName,
                retrievedAt: locationRetrievedAt
            )
            let nameIsCurrent = hasFreshGeocode
                && !isLocationNameOutdated
                && !isLocationNameStale

            if LocationNamePolicy.shouldRetryLookup(
                hasName: nameIsCurrent,
                isResolving: isResolvingLocationName,
                isRetryAllowed: isNameLookupRetryAllowed(for: .gps),
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

            refreshLocationName(
                for: location,
                saveManualCity: false,
                keepsCurrentName: hasLocationName
            )
        } else {

            setLocationNameStale(true, for: .gps)
        }
        if movedEnough,
           hasConfirmedOnboardingThisSession,
           settings.locationSource == .gps {
            Task { await loadStations(at: location.coordinate) }
        }
    }

    func refreshLocationNameIfNeeded() {
        let source = settings.locationSource
        guard hasConfirmedOnboardingThisSession,
              !isResolvingLocationName,
              let coordinate = locationCoordinate else { return }

        let retryState = locationNameRetryState(for: source)
        let hasName = hasResolvedLocationName
        let retrievedAt = source == .manual ? settings.manualCityGeocodedAt : locationRetrievedAt
        let hasFreshGeocode = LocationNamePolicy.hasFreshGeocode(
            hasName: hasName,
            retrievedAt: retrievedAt
        )
        let needsLookup = retryState.isStale
            || LocationNamePolicy.shouldRetryLookup(
                hasName: hasFreshGeocode && !retryState.isNameOutdated,
                isResolving: isResolvingLocationName,
                isRetryAllowed: retryState.isRetryAllowed(),
                appIsActive: isAppActive
            )

        if needsLookup {
            refreshLocationName(
                for: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude),
                saveManualCity: source == .manual,
                keepsCurrentName: hasName
            )
        } else {
            scheduleLocationNameRetry(for: source)
        }
    }

    func retryLocationNameAfterReconnect() {
        let source = settings.locationSource
        cancelLocationNameRetry()
        resetNameLookupBackoff(for: source)
        guard hasConfirmedOnboardingThisSession, locationCoordinate != nil else { return }
        locationLookupID &+= 1
        cancelReverseGeocoding()
        isResolvingLocationName = false
        setLocationNameStale(true, for: source)
        refreshLocationNameIfNeeded()
    }

    func handleLocationUpdateFailure(_ error: Error) {
        let code = (error as? CLError)?.code
        if let code, LocationErrorPolicy.action(for: code) == .keepTrying {

            return
        }
        Log.location.error("Location updates failed: \(error.localizedDescription, privacy: .public)")

        cancelPendingLocationStop()
        stopLocationUpdates()
        endBackgroundActivitySession()
        endLocationServiceSession()
        refreshLocationAuthorizationStatus(configureTracking: false)
        if settings.locationSource == .gps && !hasLocationAccess {
            locationName = nil
            locationCountryCode = nil
            locationRetrievedAt = nil
        }
    }

    func setAppIsActive(_ isActive: Bool) {
        isAppActive = isActive
        player.setApplicationIsActive(isActive)

        refreshLocationAuthorizationStatus(configureTracking: false)
        configureLocationUpdates()
        if isActive {
            refreshLocationNameIfNeeded()
        }
    }

    private static let locationStopGracePeriod: Duration = .seconds(8)

    // GPS tracking is needed while the app is active or audio is active; a short grace period smooths playback transitions.
    func configureLocationUpdates() {
        guard settings.locationSource == .gps else {
            cancelPendingLocationStop()
            stopLocationUpdates()
            endBackgroundActivitySession()
            endLocationServiceSession()
            return
        }

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
            // A background playback command may resume audio after the location sessions
            // were released. Do not create new Core Location sessions from that background
            // transition; wait until the app becomes active and can establish them correctly.
            let hasForegroundEstablishedBackgroundSessions =
                locationServiceSession != nil && backgroundActivitySession != nil
            guard isAppActive || hasForegroundEstablishedBackgroundSessions else {
                cancelPendingLocationStop()
                stopLocationUpdates()
                endBackgroundActivitySession()
                endLocationServiceSession()
                return
            }

            ensureLocationServiceSession()
            if player.hasActivePlayback {
                cancelPendingLocationStop()

                if backgroundActivitySession == nil {
                    backgroundActivitySession = CLBackgroundActivitySession()
                }
            }
            startLocationUpdates(allowsBackgroundLocationUpdates: player.hasActivePlayback)
        } else {

            cancelPendingLocationStop()
            stopLocationUpdates()
            endBackgroundActivitySession()
            endLocationServiceSession()
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

        guard locationStopTask == nil else { return }
        locationStopTask = Task { [weak self] in
            try? await Task.sleep(for: Self.locationStopGracePeriod)
            guard !Task.isCancelled, let self else { return }
            self.locationStopTask = nil

            if !self.shouldTrackLocation {
                self.stopLocationUpdates()
            }
            if !self.player.hasActivePlayback {
                self.endBackgroundActivitySession()
            }
            if !self.shouldTrackLocation {
                self.endLocationServiceSession()
            }
        }
    }

    private func cancelPendingLocationStop() {
        locationStopTask?.cancel()
        locationStopTask = nil
    }

    func ensureLocationServiceSession() {
        // A lock-screen playback resume must not create a new service session in the background.
        // Existing sessions established before backgrounding remain valid and are reused.
        guard isAppActive, locationServiceSession == nil else { return }
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

    func startLocationUpdates(allowsBackgroundLocationUpdates: Bool) {
        if let locationUpdateSource {
            locationUpdateSource.setAllowsBackgroundLocationUpdates(allowsBackgroundLocationUpdates)
            return
        }

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
        source.start(allowsBackgroundLocationUpdates: allowsBackgroundLocationUpdates)
    }

    func stopLocationUpdates() {
        locationUpdateSource?.stop()
        locationUpdateSource = nil
    }

    func endBackgroundActivitySession() {
        backgroundActivitySession?.invalidate()
        backgroundActivitySession = nil
    }

    // Keep the current station while it has a transmitter in range; otherwise choose the best in-range fallback.
    func checkCoverageAndSwitch() {

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
        let manualCoordinateChanged = settings.manualLatitude != coordinate.latitude
            || settings.manualLongitude != coordinate.longitude
        if manualCoordinateChanged {
            resetNameLookupBackoff(for: .manual)
            setLocationNameStale(true, for: .manual)
        }
        var value = settings
        value.locationSource = .manual
        value.manualLatitude = coordinate.latitude
        value.manualLongitude = coordinate.longitude

        if completesOnboarding {
            value.onboardingCompleted = true
        }
        settings = value
        locationCoordinate = coordinate
        if settings.manualCity == nil && locationName == nil,
           let cachedName = lastAutomaticLocationName {

            locationName = cachedName
            locationCountryCode = lastAutomaticLocationCountryCode
            locationRetrievedAt = lastAutomaticLocationRetrievedAt
        }

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

            if settings.manualCity == nil {
                locationName = lastAutomaticLocationName
                locationCountryCode = lastAutomaticLocationCountryCode
                locationRetrievedAt = lastAutomaticLocationRetrievedAt
            }
            return
        }

        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        locationCoordinate = coordinate
        if let manualCity = settings.manualCity {
            locationName = manualCity
            locationCountryCode = settings.manualCountryCode
            locationRetrievedAt = settings.manualCityGeocodedAt
        } else if locationName == nil {
            locationName = lastAutomaticLocationName
            locationCountryCode = lastAutomaticLocationCountryCode
            locationRetrievedAt = lastAutomaticLocationRetrievedAt
        }
        refreshLocationNameIfNeeded()
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

    func locationNameRetryState(for source: LocationSource) -> LocationNameRetryState {
        source == .manual ? manualLocationNameRetryState : gpsLocationNameRetryState
    }

    func updateLocationNameRetryState(
        for source: LocationSource,
        _ update: (inout LocationNameRetryState) -> Void
    ) {
        if source == .manual {
            update(&manualLocationNameRetryState)
        } else {
            update(&gpsLocationNameRetryState)
        }
    }

    var isLocationNameOutdated: Bool {
        locationNameRetryState(for: settings.locationSource).isNameOutdated
    }

    var isLocationNameStale: Bool {
        locationNameRetryState(for: settings.locationSource).isStale
    }

    func setLocationNameOutdated(_ value: Bool, for source: LocationSource) {
        updateLocationNameRetryState(for: source) { $0.isNameOutdated = value }
    }

    func setLocationNameStale(_ value: Bool, for source: LocationSource) {
        updateLocationNameRetryState(for: source) { $0.isStale = value }
    }

    func isNameLookupRetryAllowed(for source: LocationSource) -> Bool {
        locationNameRetryState(for: source).isRetryAllowed()
    }

    private func recordNameLookupFailure(for source: LocationSource) {
        updateLocationNameRetryState(for: source) { $0.recordFailure() }
    }

    private func resetNameLookupBackoff(for source: LocationSource) {
        updateLocationNameRetryState(for: source) { $0.resetBackoff() }
    }

    func cancelLocationNameRetry() {
        locationNameRetryGeneration &+= 1
        locationNameRetryTask?.cancel()
        locationNameRetryTask = nil
        locationNameRetryTaskSource = nil
    }

    private func scheduleLocationNameRetry(for source: LocationSource) {
        cancelLocationNameRetry()
        guard settings.locationSource == source,
              isAppActive,
              hasConfirmedOnboardingThisSession,
              locationCoordinate != nil,
              let retryAt = locationNameRetryState(for: source).nextRetryAt else { return }

        let delay = max(0, retryAt.timeIntervalSinceNow) + 0.25
        let generation = locationNameRetryGeneration
        locationNameRetryTaskSource = source
        locationNameRetryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  self.locationNameRetryGeneration == generation,
                  self.locationNameRetryTaskSource == source,
                  self.settings.locationSource == source else { return }
            self.locationNameRetryTask = nil
            self.locationNameRetryTaskSource = nil
            guard self.isAppActive,
                  self.hasConfirmedOnboardingThisSession,
                  self.locationCoordinate != nil else { return }
            self.refreshLocationNameIfNeeded()
        }
    }

    // A monotonically increasing request ID prevents an older geocoding result from overwriting a newer location.
    func refreshLocationName(
        for location: CLLocation,
        saveManualCity: Bool,
        keepsCurrentName: Bool = false
    ) {
        let sourceAtRequest = settings.locationSource
        guard (sourceAtRequest == .manual) == saveManualCity else { return }

        cancelLocationNameRetry()
        locationLookupID &+= 1
        let requestID = locationLookupID
        if !keepsCurrentName {
            locationName = nil
            locationCountryCode = nil
        }
        isResolvingLocationName = true
        setLocationNameStale(false, for: sourceAtRequest)
        cancelReverseGeocoding()

        reverseGeocodingTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.reverseGeocode(location)

            guard !Task.isCancelled,
                  requestID == self.locationLookupID,
                  self.settings.locationSource == sourceAtRequest else { return }

            if result.name == nil {
                self.recordNameLookupFailure(for: sourceAtRequest)
            } else {
                self.resetNameLookupBackoff(for: sourceAtRequest)
            }
            let keepsLastKnownName = result.name == nil
                && keepsCurrentName
                && self.hasResolvedLocationName
            let previousName = sourceAtRequest == .manual
                ? (self.settings.manualCity ?? self.locationName)
                : self.locationName
            let previousCountryCode = sourceAtRequest == .manual
                ? (self.settings.manualCountryCode ?? self.locationCountryCode)
                : self.locationCountryCode
            let resolvedCountryCode = result.countryCode
                ?? (result.name == nil || result.name == previousName ? previousCountryCode : nil)
            let retrievedAt = Date()
            self.locationCountryCode = resolvedCountryCode
            if keepsLastKnownName {
                self.setLocationNameOutdated(true, for: sourceAtRequest)
            } else {
                self.setLocationNameOutdated(false, for: sourceAtRequest)
                self.locationName = result.name
                self.locationRetrievedAt = result.name == nil ? nil : retrievedAt
            }
            self.isResolvingLocationName = false
            self.reverseGeocodingTask = nil
            if sourceAtRequest == .gps, !keepsLastKnownName {
                self.lastAutomaticLocationName = result.name
                self.lastAutomaticLocationCountryCode = resolvedCountryCode
                self.lastAutomaticLocationRetrievedAt = self.locationRetrievedAt
                if let name = result.name {
                    SavedLocationStorage.save(SavedLocation(
                        coordinate: location.coordinate,
                        name: name,
                        countryCode: resolvedCountryCode,
                        retrievedAt: retrievedAt
                    ))
                }
            }
            if sourceAtRequest == .manual {
                var value = self.settings
                if let name = result.name {
                    value.manualCity = name
                    value.manualCityGeocodedAt = retrievedAt
                }
                value.manualCountryCode = resolvedCountryCode
                self.settings = value
            }
            if result.name == nil {
                self.scheduleLocationNameRetry(for: sourceAtRequest)
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
