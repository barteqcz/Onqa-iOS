import Testing
import Foundation
import CoreLocation
import SQLite3
@testable import Onqa

/// Covers the retry/backoff behaviour, stream-metadata filtering, logo URL
/// upgrade and the catalog database code (validation, install and query).
@Suite
struct ReliabilityTests {
    // MARK: Retry backoff

    @Test func backoffGrowsExponentiallyAndIsCapped() {
        func delay(_ failures: Int) -> TimeInterval {
            RetryBackoff.delay(afterFailures: failures, base: 3, cap: 30)
        }
        #expect(delay(0) == 0)
        #expect(delay(1) == 3)
        #expect(delay(2) == 6)
        #expect(delay(3) == 12)
        #expect(delay(4) == 24)
        #expect(delay(5) == 30)
        #expect(delay(50) == 30)
        #expect(delay(Int.max) == 30)
    }

    @Test func backoffNeverReturnsNegativeForNegativeInput() {
        #expect(RetryBackoff.delay(afterFailures: -3, base: 3, cap: 30) == 0)
    }

    // MARK: Reverse-geocoding retry policy

    @Test func nearbyGPSFixDoesNotRetryNameLookupWhileBackingOff() {
        let origin = CLLocationCoordinate2D(latitude: 50, longitude: 19)
        let nearbyFix = CLLocationCoordinate2D(latitude: 50, longitude: 19.001)

        #expect(!StationProcessor.shouldProcessLocationUpdate(
            from: origin,
            to: nearbyFix,
            hasLocationName: false,
            isResolvingLocationName: false,
            thresholdKm: 1.0,
            isNameRetryAllowed: false
        ))
    }

    @Test func significantMovementAlwaysProcessesEvenWhileBackingOff() {
        let origin = CLLocationCoordinate2D(latitude: 50, longitude: 19)
        let farFix = CLLocationCoordinate2D(latitude: 50, longitude: 19.05)

        #expect(StationProcessor.shouldProcessLocationUpdate(
            from: origin,
            to: farFix,
            hasLocationName: false,
            isResolvingLocationName: false,
            thresholdKm: 1.0,
            isNameRetryAllowed: false
        ))
    }

    @Test func nameLookupIsRetriedOnlyWhenVisibleAndAllowed() {
        #expect(LocationNamePolicy.shouldRetryLookup(
            hasName: false, isResolving: false, isRetryAllowed: true, appIsActive: true
        ))
        #expect(!LocationNamePolicy.shouldRetryLookup(
            hasName: false, isResolving: false, isRetryAllowed: false, appIsActive: true
        ))
        #expect(!LocationNamePolicy.shouldRetryLookup(
            hasName: false, isResolving: false, isRetryAllowed: true, appIsActive: false
        ))
        #expect(!LocationNamePolicy.shouldRetryLookup(
            hasName: false, isResolving: true, isRetryAllowed: true, appIsActive: true
        ))
        #expect(!LocationNamePolicy.shouldRetryLookup(
            hasName: true, isResolving: false, isRetryAllowed: true, appIsActive: true
        ))
    }

    // MARK: Fix quality

    @Test func invalidAndStaleFixesAreRejected() {
        #expect(!LocationFixQuality.isUsable(horizontalAccuracy: -1, age: 1, isReducedAccuracy: false))
        #expect(!LocationFixQuality.isUsable(horizontalAccuracy: -1, age: 1, isReducedAccuracy: true))
        #expect(!LocationFixQuality.isUsable(horizontalAccuracy: 30, age: 3_600, isReducedAccuracy: false))
        #expect(!LocationFixQuality.isUsable(horizontalAccuracy: 100_000, age: 1, isReducedAccuracy: false))
    }

    @Test func coarseCellFixesAreStillUsableForWideCoverageAreas() {
        #expect(LocationFixQuality.isUsable(horizontalAccuracy: 3_000, age: 5, isReducedAccuracy: false))
        #expect(LocationFixQuality.isUsable(horizontalAccuracy: 10, age: 5, isReducedAccuracy: false))
    }

    @Test func approximateLocationIsAcceptedRegardlessOfAge() {
        #expect(LocationFixQuality.isUsable(horizontalAccuracy: 15_000, age: 3_600, isReducedAccuracy: true))
        #expect(!LocationFixQuality.isUsable(horizontalAccuracy: 80_000, age: 1, isReducedAccuracy: true))
    }

    @Test func clearlyMorePreciseFixRefinesACoarseOne() {
        #expect(LocationFixQuality.isRefinement(previousAccuracy: 3_000, newAccuracy: 50))
        #expect(LocationFixQuality.isRefinement(previousAccuracy: 3_000, newAccuracy: 1_500))
        #expect(!LocationFixQuality.isRefinement(previousAccuracy: 3_000, newAccuracy: 2_000))
        #expect(!LocationFixQuality.isRefinement(previousAccuracy: 800, newAccuracy: 10))
        #expect(!LocationFixQuality.isRefinement(previousAccuracy: nil, newAccuracy: 10))
        #expect(!LocationFixQuality.isRefinement(previousAccuracy: 3_000, newAccuracy: -1))
    }

    // MARK: Stream metadata

    @Test func onlyTrackTitleIdentifiersAreAccepted() {
        #expect(StreamMetadata.isTrackTitle(identifier: "icy/StreamTitle"))
        #expect(StreamMetadata.isTrackTitle(identifier: "common/title"))
        #expect(StreamMetadata.isTrackTitle(identifier: "id3/TIT2"))
        #expect(!StreamMetadata.isTrackTitle(identifier: "icy/StreamUrl"))
        #expect(!StreamMetadata.isTrackTitle(identifier: "icy/icy-name"))
        #expect(!StreamMetadata.isTrackTitle(identifier: nil))
    }

    // MARK: Logo URLs

    @Test func plainHTTPLogoURLsAreUpgradedToHTTPS() {
        let http = URL(string: "http://example.com/logo.png?size=2")!
        #expect(StationImageCache.secureURL(http).absoluteString == "https://example.com/logo.png?size=2")
    }

    @Test func httpsAndExplicitPortLogoURLsAreLeftAlone() {
        let https = URL(string: "https://example.com/logo.png")!
        let withPort = URL(string: "http://example.com:8000/logo.png")!
        #expect(StationImageCache.secureURL(https) == https)
        #expect(StationImageCache.secureURL(withPort) == withPort)
    }

    // MARK: Catalog database

    @Test func validCatalogPassesValidationAndIsQueried() throws {
        let url = try makeCatalog()
        defer { try? FileManager.default.removeItem(at: url) }

        try CatalogRepository.validateDatabase(at: url)

        // Stand 0.1 degrees of latitude (about 11 km) north of the transmitter.
        let stations = try CatalogRepository.queryCatalog(
            path: url.path,
            latitude: 50.1,
            longitude: 19.0
        )
        #expect(stations.count == 2)

        let first = try #require(stations.first { $0.name == "Radio One" })
        #expect(first.network == "Net")
        #expect(first.coverageKm == 60)
        #expect(first.transmitterName == "Tower A")
        let distance = try #require(first.distanceKm)
        #expect(abs(distance - 11.1) < 0.3)

        // Missing optional columns fall back to defaults instead of failing.
        let second = try #require(stations.first { $0.name == "Radio Two" })
        #expect(second.network == nil)
        #expect(second.streamURLHQ == nil)
    }

    @Test func catalogMissingARequiredColumnIsRejected() throws {
        let url = try makeCatalog(omitCoverageColumn: true)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: CatalogError.self) {
            try CatalogRepository.validateDatabase(at: url)
        }
    }

    @Test func nonDatabaseFileIsRejected() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("onqa-not-a-db-\(UUID().uuidString).sqlite")
        try Data("<html>503 Service Unavailable</html>".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: CatalogError.self) {
            try CatalogRepository.validateDatabase(at: url)
        }
    }

    @Test func installingACatalogReplacesTheOldOneAtomically() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("onqa-install-\(UUID().uuidString)", isDirectory: true)
        let destination = directory.appendingPathComponent("catalog.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try makeCatalog()
        let second = try makeCatalog()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        try CatalogRepository.installCatalog(from: first, to: destination)
        #expect(FileManager.default.fileExists(atPath: destination.path))

        // Installing over an existing catalog must also succeed.
        try CatalogRepository.installCatalog(from: second, to: destination)
        try CatalogRepository.validateDatabase(at: destination)
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathExtension("new").path))
    }

    @Test func invalidDownloadDoesNotReplaceAWorkingCatalog() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("onqa-keep-\(UUID().uuidString)", isDirectory: true)
        let destination = directory.appendingPathComponent("catalog.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }

        let good = try makeCatalog()
        defer { try? FileManager.default.removeItem(at: good) }
        try CatalogRepository.installCatalog(from: good, to: destination)
        let originalSize = try Data(contentsOf: destination).count

        let bad = FileManager.default.temporaryDirectory
            .appendingPathComponent("onqa-bad-\(UUID().uuidString).sqlite")
        try Data("not a database".utf8).write(to: bad)
        defer { try? FileManager.default.removeItem(at: bad) }

        #expect(throws: CatalogError.self) {
            try CatalogRepository.installCatalog(from: bad, to: destination)
        }
        #expect(try Data(contentsOf: destination).count == originalSize)
        try CatalogRepository.validateDatabase(at: destination)
    }

    // MARK: Helpers

    /// Builds a small catalog with the schema the app expects: two stations,
    /// one transmitter, one network name and one HQ stream.
    private func makeCatalog(omitCoverageColumn: Bool = false) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("onqa-catalog-test-\(UUID().uuidString).sqlite")

        var database: OpaquePointer?
        guard sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
            nil
        ) == SQLITE_OK, let database else {
            throw CatalogError.invalidDatabase
        }
        defer { sqlite3_close(database) }

        let coverageColumn = omitCoverageColumn ? "" : ", coverage_km REAL"
        let coverageValue1 = omitCoverageColumn ? "" : ", 60"
        let coverageValue2 = omitCoverageColumn ? "" : ", 30"
        let statements = [
            "CREATE TABLE stations (id INTEGER PRIMARY KEY, name TEXT, stream_url TEXT, stream_url_hq TEXT, logo TEXT, network TEXT)",
            "CREATE TABLE transmitters (id INTEGER PRIMARY KEY, name TEXT, latitude REAL, longitude REAL)",
            "CREATE TABLE station_transmitters (station_id INTEGER, transmitter_id INTEGER, display_order INTEGER\(coverageColumn))",
            "INSERT INTO stations VALUES (1, 'Radio One', 'http://one.example/stream', 'http://one.example/hq', NULL, 'Net')",
            "INSERT INTO stations VALUES (2, 'Radio Two', 'http://two.example/stream', NULL, NULL, NULL)",
            "INSERT INTO transmitters VALUES (10, 'Tower A', 50.0, 19.0)",
            "INSERT INTO station_transmitters VALUES (1, 10, 0\(coverageValue1))",
            "INSERT INTO station_transmitters VALUES (2, 10, 1\(coverageValue2))"
        ]
        for sql in statements {
            guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
                throw CatalogError.invalidDatabase
            }
        }
        return url
    }
}
