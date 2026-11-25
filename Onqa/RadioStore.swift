import Foundation
import CoreLocation
import MapKit
import Network
import Observation

enum StationCardPlaybackAction: Equatable {
    case start
    case pause
    case ignore
}

enum StationCardPlaybackPolicy {
    static func action(
        isCurrentStation: Bool,
        isPlaying: Bool,
        isBuffering: Bool,
        isReconnecting: Bool
    ) -> StationCardPlaybackAction {
        guard isCurrentStation else { return .start }
        // A repeated tap while the stream is waiting for data is not a pause request.
        if isBuffering { return .ignore }
        if isPlaying || isReconnecting { return .pause }
        return .start
    }
}

/// Observable application coordinator for settings, stations, favorites, location, catalog loading, and playback.
@MainActor
@Observable
final class RadioStore {
    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            if oldValue.locationSource != settings.locationSource {
                pendingStationCoordinate = nil
            }
            persistSettings()

            if oldValue.useHQStream != settings.useHQStream,
               let station = player.currentStation,
               player.isPlaying || player.isBuffering || player.playbackError || player.isReconnecting {
                player.play(station, useHQ: settings.useHQStream)
            }

            if oldValue.locationSource != settings.locationSource && hasConfirmedOnboardingThisSession {
                cancelLocationNameRetry()
                locationLookupID &+= 1
                cancelReverseGeocoding()
                isResolvingLocationName = false
                if settings.locationSource == .gps {
                    if let coordinate = lastAutomaticCoordinate {

                        locationCoordinate = coordinate
                        locationName = lastAutomaticLocationName
                        locationCountryCode = lastAutomaticLocationCountryCode
                        locationRetrievedAt = lastAutomaticLocationRetrievedAt

                        if let cachedStations = lastAutomaticCatalogStations,
                           let cachedCoordinate = lastAutomaticCatalogCoordinate,
                           !LocationRefreshPolicy.shouldReloadStations(
                               from: cachedCoordinate,
                               to: coordinate,
                               thresholdKm: Self.locationRefreshThresholdKm
                           ) {
                            catalogStations = cachedStations
                            rebuildStations()
                            if stations.isEmpty {
                                player.stop()
                            } else {
                                checkCoverageAndSwitch()
                            }
                        } else {
                            Task { await loadStations(at: coordinate) }
                        }
                    } else {
                        locationCoordinate = nil
                        locationName = nil
                        locationCountryCode = nil
                        locationRetrievedAt = nil
                    }

                } else {
                    loadManualCoordinate()
                    refreshStations()
                }
                refreshLocationNameIfNeeded()
                configureLocationUpdates()
            }
        }
    }

    var stations: [RadioStation] = []
    var favorites: Set<String>
    var locationCoordinate: CLLocationCoordinate2D?
    var locationName: String?
    var locationCountryCode: String?

    var locationRetrievedAt: Date?
    @ObservationIgnored var gpsLocationNameRetryState = LocationNameRetryState()
    @ObservationIgnored var manualLocationNameRetryState = LocationNameRetryState()

    var isResolvingLocationName = false
    var locationAuthorizationStatus: CLAuthorizationStatus = .notDetermined

    var hasConfirmedOnboardingThisSession = false
    var isLoading = false
    var isDownloadingCatalog = false

    var catalogStatus: CatalogStatus?
    var isNetworkAvailable = true
    var locationPermissionDenied = false
    var shouldShowLocationSettingsPrompt = false
    var errorMessage: String?
    var searchText = ""

    let player = RadioAudioPlayer()

    private let networkMonitor = NWPathMonitor()
    private let networkQueue = DispatchQueue(label: "com.barteqcz.onqa.network")
    var catalogStations: [RadioStation] = []
    var pendingStationCoordinate: CLLocationCoordinate2D?
    var locationLookupID: UInt64 = 0
    var didBootstrap = false
    var isAutomaticLocationSelectionPending = false
    /// The scheduled catalog update is only checked once per launch, so the
    /// station list is never swapped for the download card while someone is
    /// already listening. An update that cannot run now is retried on the next
    /// launch.
    var didCheckCatalogForUpdateThisLaunch = false
    var catalogPreparationTask: Task<URL, Error>?
    var catalogDownloadTask: Task<Void, Error>?
    @ObservationIgnored var locationUpdateSource: LocationUpdateSource?
    var locationServiceSession: CLServiceSession?
    var locationServiceDiagnosticsTask: Task<Void, Never>?
    var backgroundActivitySession: CLBackgroundActivitySession?
    /// Pending, debounced teardown of location tracking (see `configureLocationUpdates`).
    @ObservationIgnored var locationStopTask: Task<Void, Never>?
    /// One retry task for the active mode; inactive retry deadlines remain saved.
    @ObservationIgnored var locationNameRetryTask: Task<Void, Never>?
    @ObservationIgnored var locationNameRetryTaskSource: LocationSource?
    @ObservationIgnored var locationNameRetryGeneration: UInt64 = 0
    var reverseGeocodingTask: Task<Void, Never>?
    var reverseGeocodingRequest: MKReverseGeocodingRequest?
    /// One manager, only used to read the current authorization status.
    /// Creating a new CLLocationManager for every status check is wasteful.
    @ObservationIgnored let authorizationProbe = CLLocationManager()
    var isAppActive = false

    // Keep the automatic location separate from the currently selected manual
    // coordinate so switching back to Auto can restore its last known state.
    var lastAutomaticCoordinate: CLLocationCoordinate2D?
    var lastAutomaticLocationName: String?
    var lastAutomaticLocationCountryCode: String?
    var lastAutomaticLocationRetrievedAt: Date?
    var lastAutomaticCatalogStations: [RadioStation]?
    var lastAutomaticCatalogCoordinate: CLLocationCoordinate2D?

    static let locationRefreshThresholdKm = LocationRequestConfiguration.minimumDistance / 1_000

    private static let settingsKey = "onqa.settings.v1"
    private static let favoritesKey = "onqa.favorites.v1"
    static let catalogURL = URL(string: "https://onqa.barteq.cz/downloads/catalog.sqlite")!

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.settingsKey),
           let saved = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = saved
        } else {
            settings = AppSettings()
        }
        if let data = UserDefaults.standard.data(forKey: Self.favoritesKey),
           let saved = try? JSONDecoder().decode(Set<String>.self, from: data) {
            favorites = saved
        } else {
            favorites = []
        }
        locationAuthorizationStatus = authorizationProbe.authorizationStatus
        locationPermissionDenied = locationAuthorizationStatus == .denied
            || locationAuthorizationStatus == .restricted
        if settings.onboardingCompleted && locationPermissionDenied && settings.locationSource == .gps {
            // Preserve access to the app when a previously granted permission
            // is revoked. Manual mode remains available without GPS access.
            var value = settings
            value.locationSource = .manual
            settings = value
        }
        hasConfirmedOnboardingThisSession = settings.onboardingCompleted && (
            locationAuthorizationStatus == .authorizedWhenInUse
                || locationAuthorizationStatus == .authorizedAlways
                || settings.locationSource == .manual
        )
        if let saved = SavedLocationStorage.load() {
            restoreLastAutomaticLocation(saved)
        }
        networkMonitor.pathUpdateHandler = { [weak self] path in
            let isSatisfied = path.status == .satisfied
            Task { @MainActor in
                self?.handleNetworkChange(isAvailable: isSatisfied)
            }
        }
        networkMonitor.start(queue: networkQueue)

        player.onNext = { [weak self] in self?.playNext() }
        player.onPrevious = { [weak self] in self?.playPrevious() }
        player.onPlaybackActivityChange = { [weak self] in
            self?.configureLocationUpdates()
        }
    }
}

extension RadioStore {
    var displayedStations: [RadioStation] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return stations }
        // Case/diacritic-insensitive match without re-folding the query for every station.
        return stations.filter { $0.name.localizedStandardContains(query) }
    }
    func setAccent(_ accent: OnqaAccent) {
        var value = settings
        value.accent = accent
        settings = value
    }

    func toggleFavorite(_ station: RadioStation) {
        if favorites.contains(station.id) {
            favorites.remove(station.id)
        } else {
            favorites.insert(station.id)
        }
        persistFavorites()
        rebuildStations()
    }

    func play(_ station: RadioStation) {
        switch StationCardPlaybackPolicy.action(
            isCurrentStation: player.currentStation?.id == station.id,
            isPlaying: player.isPlaying,
            isBuffering: player.isBuffering,
            isReconnecting: player.isReconnecting
        ) {
        case .start:
            player.play(station, useHQ: settings.useHQStream)
        case .pause:
            player.pause()
        case .ignore:
            break
        }
    }

    func playNext() {
        playRelativeStation(direction: 1)
    }

    func playPrevious() {
        playRelativeStation(direction: -1)
    }

    // Wrap around at either end so next/previous always stays within the current station order.
    private func playRelativeStation(direction: Int) {
        guard !stations.isEmpty else { return }
        let currentIndex = stations.firstIndex(where: { $0.id == player.currentStation?.id }) ?? 0
        let nextIndex = (currentIndex + direction + stations.count) % stations.count
        player.play(stations[nextIndex], useHQ: settings.useHQStream)
    }

    func favoritesBackupData() -> Data {
        let backup = FavoritesBackup(favoriteStations: favorites.sorted())
        return (try? JSONEncoder().encode(backup)) ?? Data("{\"favoriteStations\":[]}".utf8)
    }

    func importFavorites(from data: Data) throws {
        let backup = try JSONDecoder().decode(FavoritesBackup.self, from: data)
        favorites = Set(backup.favoriteStations)
        persistFavorites()
        rebuildStations()
    }

    private func persistSettings() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: Self.settingsKey)
    }

    private func persistFavorites() {
        guard let data = try? JSONEncoder().encode(favorites) else { return }
        UserDefaults.standard.set(data, forKey: Self.favoritesKey)
    }
    func rebuildStations() {
        migrateLegacyFavoriteNamesIfNeeded()
        stations = StationProcessor.groupAndSort(catalogStations, favorites: favorites)
        player.hasMultipleStations = stations.count > 1
    }

    /// Older app versions stored favorites as display names. Migrate each
    /// legacy name to all matching catalog identities once the catalog is
    /// available; this preserves the old behavior for previously saved data.
    private func migrateLegacyFavoriteNamesIfNeeded() {
        let knownNames = Set(catalogStations.map(\.name))
        let legacyNames = favorites.intersection(knownNames)
        guard !legacyNames.isEmpty else { return }

        for station in catalogStations where legacyNames.contains(station.name) {
            favorites.insert(station.id)
        }
        favorites.subtract(legacyNames)
        persistFavorites()
    }
}
