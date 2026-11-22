import Foundation
import CoreLocation

/// How a failed location request affects tracking.
enum LocationErrorPolicy {
    enum Action: Equatable {
        /// Core Location keeps trying on its own and delivers a fix when it can.
        case keepTrying
        /// Updates have ended; tracking has to be started again later.
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

/// A fix reduced to plain values, so it can cross from the Core Location
/// delegate callback to the main actor without sharing a reference type.
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

/// Battery-friendly location source backed by `CLLocationManager`.
///
/// `CLLocationUpdate.liveUpdates` accepts neither a desired accuracy nor a
/// distance filter, so the system may keep the GPS powered and wake the app
/// every few seconds while someone drives, even though the app only reacts to
/// about 1 km of movement. `CLLocationManager` lets the app ask for what it
/// needs: a coarse fix (the system can use Wi-Fi and cell towers instead of
/// the GPS), delivered only after the device has moved the filter distance.
/// This mirrors the Android app's `PRIORITY_BALANCED_POWER_ACCURACY` request
/// with a 1000 m minimum distance.
///
/// Authorization is still requested through the app's `CLServiceSession`, and
/// background delivery is still kept alive by its `CLBackgroundActivitySession`;
/// this type only receives the fixes.
///
/// Create it on the main actor: Core Location delivers delegate callbacks on
/// the thread the manager was created on.
@MainActor
final class LocationUpdateSource: NSObject, CLLocationManagerDelegate {
    /// Station coverage areas are tens of kilometres wide, so a fix good to
    /// about 100 m is plenty. Anything finer would only cost battery.
    static let desiredAccuracy = kCLLocationAccuracyHundredMeters

    var onFix: (@MainActor (CLLocation) -> Void)?
    var onAuthorizationChange: (@MainActor (CLAuthorizationStatus) -> Void)?
    var onFailure: (@MainActor (Error) -> Void)?

    private let manager = CLLocationManager()
    private let distanceFilter: CLLocationDistance

    init(distanceFilter: CLLocationDistance) {
        self.distanceFilter = distanceFilter
        super.init()
    }

    func start() {
        manager.delegate = self
        manager.desiredAccuracy = Self.desiredAccuracy
        manager.distanceFilter = distanceFilter
        // Playback keeps the app running while updates matter. Automatic
        // pausing can stop delivery at a red light and not resume reliably.
        manager.pausesLocationUpdatesAutomatically = false
        // Requires the `location` background mode, which the app declares.
        // The background activity session keeps When In Use access alive.
        manager.allowsBackgroundLocationUpdates = true
        manager.startUpdatingLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.delegate = nil
        onFix = nil
        onAuthorizationChange = nil
        onFailure = nil
    }

    // MARK: CLLocationManagerDelegate

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        // The app reacts to where the device is, not to the path it took, so
        // only the newest fix of a batch matters.
        guard let latest = locations.last else { return }
        let sample = LocationSample(latest)
        Task { @MainActor [weak self] in
            self?.onFix?(sample.location)
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
