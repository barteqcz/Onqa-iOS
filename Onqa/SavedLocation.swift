import Foundation
import CoreLocation

/// The last automatically determined position together with the city it was
/// resolved to. It is kept between launches so the station list can appear at
/// once instead of waiting for the first location fix, like on Android.
///
/// The position and the name are stored as one unit and only ever written
/// together, after the city lookup for exactly that position has succeeded, so
/// a restored name never belongs to a different place than the coordinate.
struct SavedLocation: Codable, Equatable, Sendable {
    var latitude: Double
    var longitude: Double
    var name: String
    var countryCode: String?

    init(coordinate: CLLocationCoordinate2D, name: String, countryCode: String?) {
        latitude = coordinate.latitude
        longitude = coordinate.longitude
        self.name = name
        self.countryCode = countryCode
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// False for values that cannot be queried or shown, such as damaged data.
    var isValid: Bool {
        CLLocationCoordinate2DIsValid(coordinate)
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum SavedLocationStorage {
    static let key = "onqa.lastLocation.v1"

    static func load(from defaults: UserDefaults = .standard) -> SavedLocation? {
        guard let data = defaults.data(forKey: key),
              let saved = try? JSONDecoder().decode(SavedLocation.self, from: data),
              saved.isValid else { return nil }
        return saved
    }

    static func save(_ location: SavedLocation, to defaults: UserDefaults = .standard) {
        guard location.isValid,
              let data = try? JSONEncoder().encode(location) else { return }
        defaults.set(data, forKey: key)
    }
}
