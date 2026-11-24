import Foundation
import CoreLocation

 
 
 
 
 
 
 
struct SavedLocation: Codable, Equatable, Sendable {
    var latitude: Double
    var longitude: Double
    var name: String
    var countryCode: String?
     
     
    var retrievedAt: Date?

    init(
        coordinate: CLLocationCoordinate2D,
        name: String,
        countryCode: String?,
        retrievedAt: Date? = nil
    ) {
        latitude = coordinate.latitude
        longitude = coordinate.longitude
        self.name = name
        self.countryCode = countryCode
        self.retrievedAt = retrievedAt
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

     
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
