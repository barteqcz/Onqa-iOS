import Foundation
import CoreLocation
import SQLite3
import os

// Coordinates catalog refreshes and downloads; the repository below owns the SQLite file itself.
extension RadioStore {
    func handleNetworkChange(isAvailable: Bool) {
        let wasAvailable = isNetworkAvailable
        isNetworkAvailable = isAvailable
        guard isAvailable && !wasAvailable else { return }

        player.retryNow()
        retryLocationNameAfterReconnect()

        if catalogStatus == .offline {
            refreshStations()
        }
    }
    func refreshStations() {
        Task { await loadStations() }
    }

    func updateCatalogNow() {
        Task {
            do {
                try await downloadCatalog()
                await loadStations()
            } catch {
                errorMessage = String(localized: "Catalog update failed: \(error.localizedDescription)")
            }
        }
    }
    func loadStations() async {
        guard let coordinate = effectiveCoordinate() else { return }
        await loadStations(at: coordinate)
    }

    func loadStations(at coordinate: CLLocationCoordinate2D) async {

        if isLoading {
            pendingStationCoordinate = coordinate
            return
        }

        let sourceAtRequest = settings.locationSource
        isLoading = true
        errorMessage = nil
        defer {
            isLoading = false
            if let pending = pendingStationCoordinate {
                pendingStationCoordinate = nil
                Task { await loadStations(at: pending) }
            }
        }

        do {
            let database = try await ensureCatalogAvailable()
            let latitude = coordinate.latitude
            let longitude = coordinate.longitude
            let all = try await Task.detached(priority: .userInitiated) {
                try CatalogRepository.queryCatalog(path: database.path, latitude: latitude, longitude: longitude)
            }.value

            guard pendingStationCoordinate == nil,
                  settings.locationSource == sourceAtRequest else { return }

            catalogStations = all
            if settings.locationSource == .gps {
                lastAutomaticCoordinate = coordinate
                lastAutomaticCatalogStations = all
                lastAutomaticCatalogCoordinate = coordinate
            }
            rebuildStations()
            if stations.isEmpty {

                player.stop()
            } else {
                checkCoverageAndSwitch()
            }
        } catch {
            Log.catalog.error("Loading stations failed: \(error.localizedDescription, privacy: .public)")

            if catalogStatus != .offline {
                errorMessage = error.localizedDescription
            }
        }
    }

    // Share catalog preparation so simultaneous callers do not trigger duplicate downloads.
    func ensureCatalogAvailable() async throws -> URL {
        if let catalogPreparationTask {
            return try await catalogPreparationTask.value
        }

        let task = Task { try await prepareCatalog() }
        catalogPreparationTask = task
        do {
            let url = try await task.value
            catalogPreparationTask = nil
            return url
        } catch {
            catalogPreparationTask = nil
            throw error
        }
    }

    func prepareCatalog() async throws -> URL {
        let url = CatalogRepository.databaseFileURL()
        let isLaunchCheck = !didCheckCatalogForUpdateThisLaunch
        didCheckCatalogForUpdateThisLaunch = true

        if isLaunchCheck, FileManager.default.fileExists(atPath: url.path) {

            Task.detached(priority: .utility) { CatalogRepository.excludeFromBackup(url) }
        }

        if !FileManager.default.fileExists(atPath: url.path) {

            try await downloadCatalogReportingStatus(isRequired: true)
        } else if isLaunchCheck && isCatalogUpdateDue {

            Task { [weak self] in
                guard let self else { return }
                let updated = await self.refreshCatalogIgnoringFailure()
                guard updated, let coordinate = self.effectiveCoordinate() else { return }
                await self.loadStations(at: coordinate)
            }
        }
        return url
    }

    private var isCatalogUpdateDue: Bool {
        guard let interval = settings.catalogUpdateFrequency.interval else { return false }
        guard let lastUpdate = settings.lastCatalogUpdate else { return true }
        return Date().timeIntervalSince(lastUpdate) >= interval
    }

    func refreshCatalogIgnoringFailure() async -> Bool {
        do {
            try await downloadCatalogReportingStatus(isRequired: false)
            return true
        } catch {
            Log.catalog.error("Background catalog refresh failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func downloadCatalogReportingStatus(isRequired: Bool) async throws {
        guard isNetworkAvailable else {
            if isRequired { catalogStatus = .offline }
            throw CatalogError.offline
        }
        if isRequired { catalogStatus = .downloading }
        do {
            try await downloadCatalog()
            if isRequired { catalogStatus = nil }
        } catch {
            if isRequired {
                catalogStatus = CatalogError.isOffline(error) ? .offline : nil
            }
            throw error
        }
    }

    func downloadCatalog() async throws {
        if let catalogDownloadTask {
            try await catalogDownloadTask.value
            return
        }

        isDownloadingCatalog = true
        let task = Task { try await self.performCatalogDownload() }
        catalogDownloadTask = task
        defer {
            isDownloadingCatalog = false
            catalogDownloadTask = nil
        }
        try await task.value
    }

    // Use ETag validation to avoid needless downloads, then validate and replace the database as one install step.
    func performCatalogDownload() async throws {
        guard isNetworkAvailable else {
            throw CatalogError.offline
        }

        let destination = CatalogRepository.databaseFileURL()
        var request = URLRequest(url: Self.catalogURL)
        request.timeoutInterval = 30

        if let etag = settings.catalogETag, FileManager.default.fileExists(atPath: destination.path) {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        let (temporaryURL, response) = try await URLSession.shared.download(for: request)
        let http = response as? HTTPURLResponse

        if http?.statusCode == 304 {
            Log.catalog.info("Catalog is already up to date")
            recordCatalogUpdate(etag: settings.catalogETag)
            return
        }
        if let http, !(200...299).contains(http.statusCode) {
            throw CatalogError.http(http.statusCode)
        }

        try await Task.detached(priority: .utility) {
            try CatalogRepository.installCatalog(from: temporaryURL, to: destination)
        }.value

        Log.catalog.info("Catalog updated")

        lastAutomaticCatalogStations = nil
        lastAutomaticCatalogCoordinate = nil
        recordCatalogUpdate(etag: http?.value(forHTTPHeaderField: "ETag"))
    }

    func recordCatalogUpdate(etag: String?) {
        var value = settings
        value.lastCatalogUpdate = Date()
        value.catalogETag = etag
        settings = value
    }

}

enum CatalogRepository {

    static func installCatalog(from temporaryURL: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try validateDatabase(at: temporaryURL)

        let replacement = destination.appendingPathExtension("new")
        if FileManager.default.fileExists(atPath: replacement.path) {
            try FileManager.default.removeItem(at: replacement)
        }
        try FileManager.default.copyItem(at: temporaryURL, to: replacement)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: replacement)
        } else {
            try FileManager.default.moveItem(at: replacement, to: destination)
        }
        excludeFromBackup(destination)
    }

    static func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do {
            try url.setResourceValues(values)
        } catch {
            Log.catalog.error("Unable to exclude the catalog from backup: \(error.localizedDescription, privacy: .public)")
        }
    }
    static func databaseFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("catalog.sqlite")
    }

    // Check SQLite integrity and the columns the app expects before accepting a downloaded catalog.
    static func validateDatabase(at url: URL) throws {
        var database: OpaquePointer?
        let openResult = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil)
        guard openResult == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw CatalogError.invalidDatabase
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA quick_check", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw CatalogError.invalidDatabase
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let result = sqlite3_column_text(statement, 0),
              String(cString: result).lowercased() == "ok" else {
            throw CatalogError.invalidDatabase
        }

        let requiredColumns: [String: Set<String>] = [
            "stations": ["id", "name", "stream_url", "stream_url_hq", "logo", "network"],
            "transmitters": ["id", "name", "latitude", "longitude"],
            "station_transmitters": ["station_id", "transmitter_id", "display_order", "coverage_km"]
        ]
        for (table, required) in requiredColumns {
            let sql = "PRAGMA table_info(\(table))"
            var tableStatement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &tableStatement, nil) == SQLITE_OK,
                  let tableStatement else {
                throw CatalogError.invalidDatabase
            }
            var columns = Set<String>()
            var result = sqlite3_step(tableStatement)
            while result == SQLITE_ROW {
                if let name = sqlite3_column_text(tableStatement, 1) {
                    columns.insert(String(cString: name))
                }
                result = sqlite3_step(tableStatement)
            }
            sqlite3_finalize(tableStatement)
            guard result == SQLITE_DONE, required.isSubset(of: columns) else {
                throw CatalogError.invalidDatabase
            }
        }
    }

    static func queryCatalog(path: String, latitude: Double, longitude: Double) throws -> [RadioStation] {
        var database: OpaquePointer?
        let openResult = sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil)
        guard openResult == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw CatalogError.invalidDatabase
        }
        defer { sqlite3_close(database) }

        let sql = """
        SELECT
            s.name,
            s.stream_url,
            s.stream_url_hq,
            s.logo,
            s.network,
            t.id,
            t.name,
            t.latitude,
            t.longitude,
            st.display_order,
            st.coverage_km
        FROM stations s
        JOIN station_transmitters st ON s.id = st.station_id
        JOIN transmitters t ON st.transmitter_id = t.id
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw CatalogError.invalidDatabase
        }
        defer { sqlite3_finalize(statement) }

        let origin = CLLocation(latitude: latitude, longitude: longitude)

        var result: [RadioStation] = []
        var stepResult = sqlite3_step(statement)
        while stepResult == SQLITE_ROW {
            func text(_ index: Int32) -> String? {
                guard sqlite3_column_type(statement, index) != SQLITE_NULL,
                      let value = sqlite3_column_text(statement, index) else { return nil }
                return String(cString: value)
            }
            func number(_ index: Int32) -> Double? {
                guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
                return sqlite3_column_double(statement, index)
            }

            let transmitterLatitude = number(7)
            let transmitterLongitude = number(8)
            let distance: Double?
            if let transmitterLatitude, let transmitterLongitude {
                distance = origin.distance(
                    from: CLLocation(latitude: transmitterLatitude, longitude: transmitterLongitude)
                ) / 1_000
            } else {
                distance = nil
            }

            result.append(RadioStation(
                name: text(0) ?? String(localized: "Unknown station"),
                streamURL: text(1),
                streamURLHQ: text(2),
                logoURL: text(3),
                transmitterName: text(6),
                transmitterID: sqlite3_column_type(statement, 5) == SQLITE_NULL ? nil : Int(sqlite3_column_int(statement, 5)),
                network: text(4),
                distanceKm: distance,
                displayOrder: sqlite3_column_type(statement, 9) == SQLITE_NULL ? 0 : Int(sqlite3_column_int(statement, 9)),
                coverageKm: number(10)
            ))
            stepResult = sqlite3_step(statement)
        }
        guard stepResult == SQLITE_DONE else {
            throw CatalogError.queryFailed
        }
        return result
    }
}

enum CatalogStatus: Equatable {

    case downloading

    case offline
}

enum CatalogError: LocalizedError {
    case offline
    case http(Int)
    case invalidDatabase
    case queryFailed

    static func isOffline(_ error: Error) -> Bool {
        if let catalogError = error as? CatalogError, case .offline = catalogError {
            return true
        }
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .networkConnectionLost:
            return true
        default:
            return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .offline:
            return String(localized: "No internet connection. Connect to the internet and try again.")
        case .http(let code):
            return String(format: String(localized: "The radio catalog server returned HTTP %d."), code)
        case .invalidDatabase:
            return String(localized: "The downloaded radio catalog is invalid or could not be opened.")
        case .queryFailed:
            return String(localized: "The radio catalog could not be read completely. Try updating the catalog.")
        }
    }
}
