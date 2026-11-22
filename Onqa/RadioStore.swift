import Foundation
import CoreLocation
import MapKit
import Network
import Observation

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
                locationLookupID &+= 1
                cancelReverseGeocoding()
                isResolvingLocationName = false
                if settings.locationSource == .gps {
                    if let coordinate = lastAutomaticCoordinate {
                        // Restore the last automatic location immediately. The live
                        // stream supplies fresh fixes without clearing an unchanged list.
                        locationCoordinate = coordinate
                        locationName = lastAutomaticLocationName
                        locationCountryCode = lastAutomaticLocationCountryCode

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
                    }

                } else {
                    loadManualCoordinate()
                    refreshStations()
                }
                configureLocationUpdates()
            }
        }
    }

    var stations: [RadioStation] = []
    var favorites: Set<String>
    var locationCoordinate: CLLocationCoordinate2D?
    var locationName: String?
    var locationCountryCode: String?
    /// True from the moment a reverse-geocode starts until it finishes, so the
    /// UI can tell "still looking up the name" apart from "no name found".
    var isResolvingLocationName = false
    var locationAuthorizationStatus: CLAuthorizationStatus = .notDetermined
    // Session-only confirmation prevents an Allow Once grant from skipping
    // onboarding on the next launch, while permanent When In Use access does.
    var hasConfirmedOnboardingThisSession = false
    var isLoading = false
    var isDownloadingCatalog = false
    /// What the home screen shows in place of the station list while the
    /// catalog downloads (or cannot), or nil otherwise. Set only for downloads
    /// the person has to wait for (the first-launch download and the update
    /// check at launch), never for the manual "Update now" button in Settings,
    /// which has its own spinner.
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
    var reverseGeocodingTask: Task<Void, Never>?
    var reverseGeocodingRequest: MKReverseGeocodingRequest?
    var nameLookupFailures = 0
    var nextNameLookupDate: Date?
    /// Set when a fix was accepted while the app was in the background, where
    /// reverse geocoding is skipped; the name is refreshed on return to the
    /// foreground.
    @ObservationIgnored var isLocationNameStale = false
    /// One manager, only used to read the current authorization status.
    /// Creating a new CLLocationManager for every status check is wasteful.
    @ObservationIgnored let authorizationProbe = CLLocationManager()
    var isAppActive = true

    // Keep the automatic location separate from the currently selected manual
    // coordinate so switching back to Auto can restore its last known state.
    var lastAutomaticCoordinate: CLLocationCoordinate2D?
    var lastAutomaticLocationName: String?
    var lastAutomaticLocationCountryCode: String?
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
        if player.currentStation?.id == station.id && (player.isPlaying || player.isBuffering || player.isReconnecting) {
            player.pause()
        } else {
            player.play(station, useHQ: settings.useHQStream)
        }
    }

    func playNext() {
        playRelativeStation(direction: 1)
    }

    func playPrevious() {
        playRelativeStation(direction: -1)
    }

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
