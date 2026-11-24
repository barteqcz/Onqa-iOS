import Foundation
import CoreLocation

enum LocationErrorPolicy {
    enum Action: Equatable {

        case keepTrying

        case stopTracking
    }

    static func action(for code: CLError.Code) -> Action {
        switch code {
        case .locationUnknown, .network:
            return .keepTrying
        default:
            return .stopTracking
        }
    }
}

enum LocationRequestConfiguration {
    static let desiredAccuracy: CLLocationAccuracy = kCLLocationAccuracyHundredMeters
    static let minimumUpdateInterval: TimeInterval = 15
    static let minimumDistance: CLLocationDistance = 1_000
}

enum LocationUpdateTimingPolicy {
    static func shouldDeliver(timestamp: Date, after previousTimestamp: Date?) -> Bool {
        guard let previousTimestamp else { return true }
        return timestamp.timeIntervalSince(previousTimestamp) >= LocationRequestConfiguration.minimumUpdateInterval
    }
}

// Copy CLLocation into Sendable scalar values before hopping from the delegate callback to the main actor.
private struct LocationSample: Sendable {
    let latitude: Double
    let longitude: Double
    let horizontalAccuracy: Double
    let timestamp: Date

    init(_ location: CLLocation) {
        latitude = location.coordinate.latitude
        longitude = location.coordinate.longitude
        horizontalAccuracy = location.horizontalAccuracy
        timestamp = location.timestamp
    }

    var location: CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            altitude: 0,
            horizontalAccuracy: horizontalAccuracy,
            verticalAccuracy: -1,
            timestamp: timestamp
        )
    }
}

/// Owns CLLocationManager and forwards rate-limited fixes, authorization changes, and failures to RadioStore.
@MainActor
final class LocationUpdateSource: NSObject, CLLocationManagerDelegate {
    private var lastDeliveredLocationTimestamp: Date?

    var onFix: (@MainActor (CLLocation) -> Void)?
    var onAuthorizationChange: (@MainActor (CLAuthorizationStatus) -> Void)?
    var onFailure: (@MainActor (Error) -> Void)?

    private let manager = CLLocationManager()

    func start() {
        lastDeliveredLocationTimestamp = nil
        manager.delegate = self
        manager.desiredAccuracy = LocationRequestConfiguration.desiredAccuracy
        manager.distanceFilter = LocationRequestConfiguration.minimumDistance

        manager.pausesLocationUpdatesAutomatically = false

        manager.allowsBackgroundLocationUpdates = true
        manager.startUpdatingLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.delegate = nil
        lastDeliveredLocationTimestamp = nil
        onFix = nil
        onAuthorizationChange = nil
        onFailure = nil
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {

        guard let latest = locations.last else { return }
        let sample = LocationSample(latest)
        Task { @MainActor [weak self] in
            guard let self,
                  LocationUpdateTimingPolicy.shouldDeliver(
                    timestamp: sample.timestamp,
                    after: self.lastDeliveredLocationTimestamp
                  ) else { return }
            self.lastDeliveredLocationTimestamp = sample.timestamp
            self.onFix?(sample.location)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.onAuthorizationChange?(self.manager.authorizationStatus)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.onFailure?(error)
        }
    }
}
