import Testing
import Foundation
import CoreLocation
import Observation
@testable import Onqa

@Suite
struct OnqaTests {

    @Test func streamURLsAllowOnlyHTTPAndHTTPS() {
        var station = RadioStation(
            name: "Test station",
            streamURL: "http://example.com/stream",
            streamURLHQ: "https://example.com/high",
            logoURL: nil,
            transmitterName: nil,
            transmitterID: nil,
            network: nil,
            distanceKm: nil,
            displayOrder: 0,
            coverageKm: nil
        )

        #expect(station.streamURL(useHQ: false)?.scheme?.lowercased() == "http")
        #expect(station.streamURL(useHQ: true)?.scheme?.lowercased() == "https")

        station.streamURL = "HTTP://example.com/stream"
        #expect(station.streamURL(useHQ: false) != nil)

        for rejectedURL in [
            "file:///tmp/stream",
            "ftp://example.com/stream",
            "custom://example.com/stream",
            "javascript:alert(1)",
            "//example.com/stream",
            "example.com/stream"
        ] {
            station.streamURL = rejectedURL
            #expect(station.streamURL(useHQ: false) == nil)
        }
    }
    @Test func androidLocationRequestConfigurationIsPreservedOnIOS() {
        #expect(LocationRequestConfiguration.desiredAccuracy == kCLLocationAccuracyHundredMeters)
        #expect(LocationRequestConfiguration.minimumUpdateInterval == 15)
        #expect(LocationRequestConfiguration.minimumDistance == 1_000)
    }

    @Test func locationUpdatesRespectAndroidMinimumInterval() {
        let first = Date(timeIntervalSince1970: 1_000)
        #expect(LocationUpdateTimingPolicy.shouldDeliver(timestamp: first, after: nil))
        #expect(!LocationUpdateTimingPolicy.shouldDeliver(
            timestamp: first.addingTimeInterval(14.9), after: first
        ))
        #expect(LocationUpdateTimingPolicy.shouldDeliver(
            timestamp: first.addingTimeInterval(15), after: first
        ))
        #expect(!LocationUpdateTimingPolicy.shouldDeliver(
            timestamp: first.addingTimeInterval(-1), after: first
        ))
    }

    @Test func locationFixQualityDoesNotAddAnAndroidAbsentAccuracyThreshold() {
        #expect(!LocationFixQuality.isUsable(horizontalAccuracy: -1))
        #expect(LocationFixQuality.isUsable(horizontalAccuracy: 0))
        #expect(LocationFixQuality.isUsable(horizontalAccuracy: 1_000))
    }

    @Test func coreLocationDistanceForOneDegreeOfLongitude() {
        let distance = StationProcessor.distanceKm(
            from: 0,
            longitude: 0,
            to: 0,
            longitude: 1
        )
        #expect(abs((distance) - (111.195)) <= 0.2)
    }

    @Test func locationRefreshRequiresAtLeastOneKilometerOfMovement() {
        let origin = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        let lessThanOneKilometer = CLLocationCoordinate2D(latitude: 0, longitude: 0.008)
        let moreThanOneKilometer = CLLocationCoordinate2D(latitude: 0, longitude: 0.010)

        #expect(!(StationProcessor.hasMoved(
            atLeast: 1.0,
            from: origin,
            to: lessThanOneKilometer
        )))
        #expect(StationProcessor.hasMoved(
            atLeast: 1.0,
            from: origin,
            to: moreThanOneKilometer
        ))
    }

    @Test func locationUpdateProcessingUsesMovementThresholdAndAcceptsInitialFix() {
        let origin = CLLocationCoordinate2D(latitude: 50, longitude: 19)
        let nearbyFix = CLLocationCoordinate2D(latitude: 50, longitude: 19.001)
        let significantFix = CLLocationCoordinate2D(latitude: 50, longitude: 19.02)

        #expect(!StationProcessor.shouldProcessLocationUpdate(
            from: origin,
            to: nearbyFix,
            thresholdKm: 1.0
        ))
        #expect(StationProcessor.shouldProcessLocationUpdate(
            from: origin,
            to: significantFix,
            thresholdKm: 1.0
        ))
        #expect(StationProcessor.shouldProcessLocationUpdate(
            from: nil,
            to: nearbyFix,
            thresholdKm: 1.0
        ))
    }

    @Test func manualLocationShowsLoadingWhileReverseGeocodingWithoutGPSPermission() {
        #expect(LocationPresentation.isPending(
            source: .manual,
            permissionDenied: true,
            resolvingName: true,
            hasName: false,
            hasCoordinate: true
        ))
    }

    @Test func manualLocationStopsLoadingWhenReverseGeocodingFinishesWithoutAName() {
        #expect(!(LocationPresentation.isPending(
            source: .manual,
            permissionDenied: true,
            resolvingName: false,
            hasName: false,
            hasCoordinate: true
        )))
    }

    @Test func knownManualLocationDoesNotShowLoadingIndicator() {
        #expect(!(LocationPresentation.isPending(
            source: .manual,
            permissionDenied: true,
            resolvingName: true,
            hasName: true,
            hasCoordinate: true
        )))
    }

    @Test func cachedAutomaticLocationDoesNotReloadStationsWhenUnchanged() {
        let coordinate = CLLocationCoordinate2D(latitude: 50, longitude: 19)

        #expect(!(LocationRefreshPolicy.shouldReloadStations(
            from: coordinate,
            to: coordinate,
            thresholdKm: 1.0
        )))
    }

    @Test func cachedAutomaticLocationReloadsStationsAfterSignificantMovement() {
        let previous = CLLocationCoordinate2D(latitude: 50, longitude: 19)
        let moved = CLLocationCoordinate2D(latitude: 50, longitude: 19.02)

        #expect(LocationRefreshPolicy.shouldReloadStations(
            from: previous,
            to: moved,
            thresholdKm: 1.0
        ))
    }

    @Test func backgroundLocationTrackingContinuesForAllActivePlaybackStates() {
        #expect(LocationTrackingPolicy.shouldTrack(
            source: .gps,
            hasLocationAccess: true,
            appIsActive: true,
            hasActivePlayback: false
        ))
        // Playing, buffering and reconnecting all count as active playback.
        #expect(LocationTrackingPolicy.shouldTrack(
            source: .gps,
            hasLocationAccess: true,
            appIsActive: false,
            hasActivePlayback: true
        ))
        #expect(!(LocationTrackingPolicy.shouldTrack(
            source: .gps,
            hasLocationAccess: true,
            appIsActive: false,
            hasActivePlayback: false
        )))
        #expect(!(LocationTrackingPolicy.shouldTrack(
            source: .manual,
            hasLocationAccess: true,
            appIsActive: true,
            hasActivePlayback: true
        )))
        #expect(!(LocationTrackingPolicy.shouldTrack(
            source: .gps,
            hasLocationAccess: false,
            appIsActive: true,
            hasActivePlayback: true
        )))
    }

    @Test func backgroundLocationTrackingContinuesUntilStopGraceExpires() {
        #expect(LocationTrackingPolicy.shouldKeepTrackingDuringStopGrace(
            source: .gps,
            hasLocationAccess: true,
            hasBackgroundActivitySession: true,
            hasPendingStop: true
        ))
        #expect(!(LocationTrackingPolicy.shouldKeepTrackingDuringStopGrace(
            source: .gps,
            hasLocationAccess: true,
            hasBackgroundActivitySession: true,
            hasPendingStop: false
        )))
        #expect(!(LocationTrackingPolicy.shouldKeepTrackingDuringStopGrace(
            source: .manual,
            hasLocationAccess: true,
            hasBackgroundActivitySession: true,
            hasPendingStop: true
        )))
        #expect(!(LocationTrackingPolicy.shouldKeepTrackingDuringStopGrace(
            source: .gps,
            hasLocationAccess: false,
            hasBackgroundActivitySession: true,
            hasPendingStop: true
        )))
    }

    @Test func sameStationNameOnDifferentNetworksHasIndependentFavorites() {
        let networkA = RadioStation(
            name: "Shared FM",
            streamURL: "https://example.com/a",
            streamURLHQ: nil,
            logoURL: nil,
            transmitterName: "A transmitter",
            transmitterID: 1,
            network: "Network A",
            distanceKm: 4,
            displayOrder: 1,
            coverageKm: 50
        )
        let networkB = RadioStation(
            name: "Shared FM",
            streamURL: "https://example.com/b",
            streamURLHQ: nil,
            logoURL: nil,
            transmitterName: "B transmitter",
            transmitterID: 2,
            network: "Network B",
            distanceKm: 6,
            displayOrder: 1,
            coverageKm: 50
        )

        let result = StationProcessor.groupAndSort(
            [networkA, networkB],
            favorites: [networkA.id]
        )

        #expect(result.count == 2)
        #expect(result.first(where: { $0.network == "Network A" })?.isFavorite == true)
        #expect(result.first(where: { $0.network == "Network B" })?.isFavorite == false)
        #expect(networkA.id != networkB.id)
    }

    @Test func duplicateTransmittersCollapseToNearestRepresentative() {
        let farther = RadioStation(
            name: "Radio One",
            streamURL: "https://example.com/stream",
            streamURLHQ: nil,
            logoURL: nil,
            transmitterName: "Hill",
            transmitterID: 10,
            network: "Example",
            distanceKm: 18,
            displayOrder: 1,
            coverageKm: 80
        )
        let nearer = RadioStation(
            name: "Radio One",
            streamURL: "https://example.com/stream",
            streamURLHQ: nil,
            logoURL: nil,
            transmitterName: "Town",
            transmitterID: 11,
            network: "Example",
            distanceKm: 4,
            displayOrder: 2,
            coverageKm: 80
        )
        let favorite = RadioStation(
            name: "Favorite FM",
            streamURL: "https://example.com/favorite",
            streamURLHQ: nil,
            logoURL: nil,
            transmitterName: "Center",
            transmitterID: 12,
            network: "Favorite network",
            distanceKm: 30,
            displayOrder: 1,
            coverageKm: 80
        )

        let result = StationProcessor.groupAndSort(
            [farther, nearer, favorite],
            favorites: [favorite.id]
        )

        #expect(result.count == 2)
        #expect(result.first?.name == "Favorite FM")
        #expect(result.last?.transmitterName == "Town")
        #expect(result.last?.distanceKm == 4)
    }

    @Test func outOfCoverageAndZeroCoverageStationsAreExcluded() {
        let outOfRange = RadioStation(
            name: "Far FM",
            streamURL: "https://example.com/far",
            streamURLHQ: nil,
            logoURL: nil,
            transmitterName: "Far",
            transmitterID: 1,
            network: nil,
            distanceKm: 50,
            displayOrder: 0,
            coverageKm: 20
        )
        let disabled = RadioStation(
            name: "Disabled FM",
            streamURL: "https://example.com/disabled",
            streamURLHQ: nil,
            logoURL: nil,
            transmitterName: "Disabled",
            transmitterID: 2,
            network: nil,
            distanceKm: 2,
            displayOrder: 0,
            coverageKm: 0
        )

        #expect(StationProcessor.groupAndSort([outOfRange, disabled], favorites: []).isEmpty)
    }

    @Test func stationsWithUnknownDistanceOrCoverageAreKept() {
        let unknownDistance = RadioStation(
            name: "No Distance FM",
            streamURL: "https://example.com/no-distance",
            streamURLHQ: nil,
            logoURL: nil,
            transmitterName: nil,
            transmitterID: nil,
            network: nil,
            distanceKm: nil,
            displayOrder: 0,
            coverageKm: 30
        )
        let unknownCoverage = RadioStation(
            name: "No Coverage FM",
            streamURL: "https://example.com/no-coverage",
            streamURLHQ: nil,
            logoURL: nil,
            transmitterName: nil,
            transmitterID: nil,
            network: nil,
            distanceKm: 12,
            displayOrder: 0,
            coverageKm: nil
        )

        let result = StationProcessor.groupAndSort([unknownDistance, unknownCoverage], favorites: [])

        #expect(result.count == 2)
        // A known distance sorts ahead of an unknown one.
        #expect(result.first?.name == "No Coverage FM")
    }

    @Test func stationExactlyAtTheCoverageEdgeIsKept() {
        let atEdge = RadioStation(
            name: "Edge FM",
            streamURL: "https://example.com/edge",
            streamURLHQ: nil,
            logoURL: nil,
            transmitterName: "Edge",
            transmitterID: 1,
            network: nil,
            distanceKm: 25,
            displayOrder: 0,
            coverageKm: 25
        )

        #expect(StationProcessor.groupAndSort([atEdge], favorites: []).count == 1)
    }

    @Test func logoFormatDetectsSVGByContentNotExtension() {
        let svg = Data("<?xml version=\"1.0\"?><SVG xmlns=\"http://www.w3.org/2000/svg\"></SVG>".utf8)
        #expect(StationLogoFormat.svgData(from: svg) != nil)
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00])
        #expect(StationLogoFormat.svgData(from: png) == nil)
    }

    @Test func gzipSVGWithOptionalExtraFieldIsDecoded() {
        // Gzip FEXTRA is present, with a three-byte extra field before DEFLATE.
        let compressed = Data(base64Encoded:
            "H4sIBAAAAAAA/wMAeHl6sykuS1eoyM3JK7ZVyigpKbDS1y8vL9crN9bLL0rXNzIwMNAHqlCysylKTS5RKM9MKcmwVTJUUshIzUzPKAEx9e1sQErsANOS1ClKAAAA"
        )!
        let decoded = StationLogoFormat.svgData(from: compressed)
        #expect(String(data: decoded ?? Data(), encoding: .utf8) == #"<svg xmlns="http://www.w3.org/2000/svg"><rect width="1" height="1"/></svg>"#)
    }


    @Test func gzipExpansionLimitIsEnforcedEvenWhenISIZEIsUnderstated() throws {
        let svg = Data(
            ("<svg>" + String(
                repeating: "x",
                count: StationLogoFormat.maximumDecompressedBytes
            )).utf8
        )
        let deflated = try (svg as NSData).compressed(using: .zlib) as Data
        var gzip = Data([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 3])
        gzip.append(deflated)
        // Deliberately claim a one-byte expansion to prove the real output,
        // rather than the modulo-2^32 trailer field, is what gets bounded.
        gzip.append(contentsOf: [0, 0, 0, 0, 1, 0, 0, 0])

        #expect(StationLogoFormat.svgData(from: gzip) == nil)
    }

    // MARK: Distance formatting

    @Test func distanceFormattingKilometersAndMiles() {
        let km = DistanceUnit.kilometers.formatted(kilometers: 12.4)
        #expect(km.contains("12"), "\(km)")
        #expect(km.lowercased().contains("km"), "\(km)")

        let miles = DistanceUnit.miles.formatted(kilometers: 16.0934)
        #expect(miles.contains("10"), "\(miles)")
        #expect(miles.lowercased().contains("mi"), "\(miles)")
    }

    @Test func distanceFormattingBelowOneUnitUsesLessThan() {
        #expect(DistanceUnit.kilometers.formatted(kilometers: 0.4).hasPrefix("< 1"))
        // 1 km is under one mile.
        #expect(DistanceUnit.miles.formatted(kilometers: 1).hasPrefix("< 1"))
    }

    @Test func distanceUnitFollowsTheSystemMeasurementSystem() {
        #expect(DistanceUnit(measurementSystem: .metric) == .kilometers)
        #expect(DistanceUnit(measurementSystem: .us) == .miles)
        // UK roads are signed in miles.
        #expect(DistanceUnit(measurementSystem: .uk) == .miles)
    }

    @Test func settingsSavedWithTheRetiredDistanceUnitKeyStillDecode() throws {
        // Earlier builds persisted a user-selectable unit that is now automatic.
        let json = #"{"onboardingCompleted":true,"distanceUnit":"miles","useHQStream":false}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: json)
        #expect(decoded.onboardingCompleted)
        #expect(!decoded.useHQStream)
    }

    // MARK: Settings

    @Test func catalogUpdateIntervals() {
        #expect(CatalogUpdateFrequency.manual.interval == nil)
        #expect(CatalogUpdateFrequency.daily.interval == TimeInterval(86_400))
        #expect(CatalogUpdateFrequency.weekly.interval == TimeInterval(7 * 86_400))
        #expect(CatalogUpdateFrequency.monthly.interval == TimeInterval(30 * 86_400))
    }

    @Test func settingsDecodeFromBeforeTheETagFieldExisted() throws {
        // Settings saved by an older build have no catalogETag key.
        let json = #"{"onboardingCompleted":true,"useHQStream":false}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: json)
        #expect(decoded.onboardingCompleted)
        #expect(!decoded.useHQStream)
        #expect(decoded.catalogETag == nil)
        #expect(decoded.locationSource == .gps)
    }

    @Test func settingsRoundTrip() throws {
        var settings = AppSettings()
        settings.locationSource = .manual
        settings.manualLatitude = 52.2
        settings.manualLongitude = 21.0
        settings.manualLocationRetrievedAt = Date(timeIntervalSince1970: 1_800_000_000)
        settings.catalogETag = "\"abc\""
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(AppSettings.self, from: data) == settings)
    }

    // MARK: Catalog storage

    @Test func downloadedCatalogIsExcludedFromBackup() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("onqa-backup-test-\(UUID().uuidString).sqlite")
        try Data("catalog".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        CatalogRepository.excludeFromBackup(url)

        let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    // MARK: Catalog errors

    @Test func offlineErrorsAreRecognised() {
        #expect(CatalogError.isOffline(CatalogError.offline))
        #expect(CatalogError.isOffline(URLError(.notConnectedToInternet)))
        #expect(CatalogError.isOffline(URLError(.dataNotAllowed)))
        #expect(!CatalogError.isOffline(URLError(.timedOut)))
        #expect(!CatalogError.isOffline(CatalogError.http(500)))
        #expect(!CatalogError.isOffline(CatalogError.invalidDatabase))
    }

    @MainActor
    @Test func citySearchResultsAreObservable() {
        let model = CitySearchModel()
        let flag = ObservationChangeFlag()

        withObservationTracking {
            _ = model.results
        } onChange: {
            flag.markChanged()
        }

        model.setResults([CitySearchResult(title: "Gliwice", subtitle: "Poland")])
        #expect(flag.hasChanged)
        #expect(model.results.map(\.title) == ["Gliwice"])
    }

}


private final class ObservationChangeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var changed = false

    func markChanged() {
        lock.lock()
        changed = true
        lock.unlock()
    }

    var hasChanged: Bool {
        lock.lock()
        defer { lock.unlock() }
        return changed
    }
}

/// Store behaviour that does not need location services or the network.
@MainActor
@Suite(.serialized)
final class RadioStoreTests {
    // Serialized: every test reads and writes the shared settings entry in
    // UserDefaults. A fresh instance (init/deinit) wraps each test.
    private let savedSettings: Data?
    private let savedLastLocation: Data?

    init() {
        savedSettings = UserDefaults.standard.data(forKey: "onqa.settings.v1")
        savedLastLocation = UserDefaults.standard.data(forKey: SavedLocationStorage.key)
        UserDefaults.standard.removeObject(forKey: "onqa.settings.v1")
        UserDefaults.standard.removeObject(forKey: SavedLocationStorage.key)
    }

    deinit {
        if let savedSettings {
            UserDefaults.standard.set(savedSettings, forKey: "onqa.settings.v1")
        } else {
            UserDefaults.standard.removeObject(forKey: "onqa.settings.v1")
        }
        if let savedLastLocation {
            UserDefaults.standard.set(savedLastLocation, forKey: SavedLocationStorage.key)
        } else {
            UserDefaults.standard.removeObject(forKey: SavedLocationStorage.key)
        }
    }

    @Test func manualModeWithoutLocationIsRetainedWhenGPSAccessIsUnavailable() {
        let store = RadioStore()
        var settings = store.settings
        settings.locationSource = .manual
        settings.manualLatitude = nil
        settings.manualLongitude = nil
        store.settings = settings

        store.revertToAutoIfManualLocationMissing()

        #expect(store.settings.locationSource == .manual)
    }

    @Test func changingLocationSourceClearsQueuedStationCoordinate() {
        let store = RadioStore()
        store.pendingStationCoordinate = CLLocationCoordinate2D(latitude: 50.0, longitude: 19.0)

        var settings = store.settings
        settings.locationSource = settings.locationSource == .gps ? .manual : .gps
        store.settings = settings

        #expect(store.pendingStationCoordinate == nil)
    }

    @Test func manualModeWithPickedLocationIsKept() {
        let store = RadioStore()
        var settings = store.settings
        settings.locationSource = .manual
        settings.manualLatitude = 50.06
        settings.manualLongitude = 19.94
        store.settings = settings

        store.revertToAutoIfManualLocationMissing()

        #expect(store.settings.locationSource == .manual)
    }

    @Test func autoModeShowsSpinnerUntilLocationArrives() {
        let store = RadioStore()
        var settings = store.settings
        settings.locationSource = .gps
        store.settings = settings

        #expect(store.isLocationPending || store.locationPermissionDenied)
    }

    @Test func manualModeWithoutNameShowsUnknownLocation() {
        let store = RadioStore()
        var settings = store.settings
        settings.locationSource = .manual
        settings.manualLatitude = 1
        settings.manualLongitude = 1
        settings.manualCity = nil
        store.settings = settings

        #expect(!store.isLocationPending)
        #expect(store.locationLabel == String(localized: "Unknown location"))
    }

    @Test func manualCityIsShownWithoutRegionSuffix() {
        let store = RadioStore()
        var settings = store.settings
        settings.locationSource = .manual
        settings.manualLatitude = 1
        settings.manualLongitude = 1
        settings.manualCity = "Kraków, Lesser Poland"
        store.settings = settings

        #expect(store.locationLabel == "Kraków")
    }

    private var savedGliwice: SavedLocation {
        SavedLocation(
            coordinate: CLLocationCoordinate2D(latitude: 50.29, longitude: 18.67),
            name: "Gliwice",
            countryCode: "PL"
        )
    }

    @Test func savedLocationIsShownImmediatelyInAutoMode() {
        let store = RadioStore()
        var settings = store.settings
        settings.locationSource = .gps
        store.settings = settings
        store.hasConfirmedOnboardingThisSession = true

        store.restoreLastAutomaticLocation(savedGliwice)

        // No wait for the first fix: the header and station list can render.
        #expect(store.locationCoordinate != nil)
        #expect(!store.isLocationPending)
        #expect(store.locationLabel == "Gliwice")
        #expect(store.locationCountryCode == "PL")
    }

    @Test func savedLocationRestoresItsRetrievalTime() {
        let store = RadioStore()
        var settings = store.settings
        settings.locationSource = .gps
        store.settings = settings
        store.hasConfirmedOnboardingThisSession = true
        let retrievedAt = Date().addingTimeInterval(-600)

        store.restoreLastAutomaticLocation(SavedLocation(
            coordinate: CLLocationCoordinate2D(latitude: 50.29, longitude: 18.67),
            name: "Gliwice",
            countryCode: "PL",
            retrievedAt: retrievedAt
        ))

        // The last known city stays visible, with a counter beside it.
        #expect(store.locationLabel == "Gliwice")
        #expect(store.locationRetrievedAt == retrievedAt)
        #expect(store.locationAgeText() != nil)
    }

    @Test func ageIsShownForManualLocation() {
        let store = RadioStore()
        var settings = store.settings
        settings.locationSource = .manual
        settings.manualLatitude = 50.29
        settings.manualLongitude = 18.67
        settings.manualCity = "Gliwice"
        settings.manualLocationRetrievedAt = Date().addingTimeInterval(-600)
        store.settings = settings

        #expect(store.locationAgeText() != nil)
    }

    @Test func savedLocationIsNotShownBeforeOnboardingIsConfirmed() {
        let store = RadioStore()
        var settings = store.settings
        settings.locationSource = .gps
        store.settings = settings
        store.hasConfirmedOnboardingThisSession = false

        store.restoreLastAutomaticLocation(savedGliwice)

        #expect(store.locationCoordinate == nil)
        #expect(store.locationName == nil)
        // It is still kept, so switching to Auto later can restore it.
        #expect(store.lastAutomaticLocationName == "Gliwice")
        #expect(store.lastAutomaticCoordinate != nil)
    }

    @Test func savedLocationDoesNotReplaceManualLocation() {
        let store = RadioStore()
        var settings = store.settings
        settings.locationSource = .manual
        settings.manualLatitude = 52.23
        settings.manualLongitude = 21.01
        store.settings = settings
        store.hasConfirmedOnboardingThisSession = true

        store.restoreLastAutomaticLocation(savedGliwice)

        #expect(store.locationCoordinate == nil)
        #expect(store.lastAutomaticLocationName == "Gliwice")
    }
}
