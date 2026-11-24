import Foundation

enum OnqaTheme: String, CaseIterable, Codable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return String(localized: "System")
        case .light: return String(localized: "Light")
        case .dark: return String(localized: "Dark")
        }
    }
}

enum OnqaAccent: String, CaseIterable, Codable, Identifiable {
    case green, purple, cyan, orange, blue
    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var color: ColorToken {
        switch self {
        case .green: return ColorToken(red: 160, green: 217, blue: 149)
        case .purple: return ColorToken(red: 208, green: 188, blue: 255)
        case .cyan: return ColorToken(red: 3, green: 218, blue: 197)
        case .orange: return ColorToken(red: 255, green: 183, blue: 77)
        case .blue: return ColorToken(red: 100, green: 181, blue: 246)
        }
    }
}

struct ColorToken {
    let red: Double
    let green: Double
    let blue: Double
    init(red: Double, green: Double, blue: Double) {
        self.red = red / 255
        self.green = green / 255
        self.blue = blue / 255
    }
}

/// Distance unit shown on station cards. It is never stored: it follows the
/// system's Measurement System (Settings > General > Language & Region).
enum DistanceUnit {
    case kilometers, miles

    /// Metric regions use kilometres. The US and UK systems both use miles
    /// for road distances.
    init(measurementSystem: Locale.MeasurementSystem) {
        self = measurementSystem == .metric ? .kilometers : .miles
    }

    /// Locale-aware distance text ("12 km", "7 mi", "< 1 km") for a distance in kilometres.
    func formatted(kilometers: Double) -> String {
        let unit: UnitLength = self == .miles ? .miles : .kilometers
        let value = Measurement(value: kilometers, unit: UnitLength.kilometers).converted(to: unit)
        let style = Measurement<UnitLength>.FormatStyle(
            width: .abbreviated,
            usage: .asProvided,
            numberFormatStyle: .number.precision(.fractionLength(0))
        )
        if value.value < 1 {
            return "< " + Measurement(value: 1, unit: unit).formatted(style)
        }
        return value.formatted(style)
    }
}

enum LocationSource: String, CaseIterable, Codable, Identifiable {
    case gps, manual
    var id: String { rawValue }
    var title: String { self == .gps ? String(localized: "Auto") : String(localized: "Manual") }
}

enum CatalogUpdateFrequency: String, CaseIterable, Codable, Identifiable {
    case manual, daily, weekly, monthly
    var id: String { rawValue }
    var title: String {
        switch self {
        case .manual: return String(localized: "Manual")
        case .daily: return String(localized: "Daily")
        case .weekly: return String(localized: "Weekly")
        case .monthly: return String(localized: "Monthly")
        }
    }
    var interval: TimeInterval? {
        switch self {
        case .manual: return nil
        case .daily: return 24 * 60 * 60
        case .weekly: return 7 * 24 * 60 * 60
        case .monthly: return 30 * 24 * 60 * 60
        }
    }
}

struct AppSettings: Codable, Equatable {
    var onboardingCompleted = false
    var theme: OnqaTheme = .dark
    var accent: OnqaAccent = .green
    var useHQStream = true
    var showLocationHeader = true
    var locationSource: LocationSource = .gps
    var manualLatitude: Double?
    var manualLongitude: Double?
    var manualCity: String?
    /// Country code returned by the last successful reverse geocode for the manual city.
    var manualCountryCode: String?
    /// Timestamp of the last successful reverse geocode for the cached manual city.
    var manualCityGeocodedAt: Date?
    var catalogUpdateFrequency: CatalogUpdateFrequency = .weekly
    var lastCatalogUpdate: Date?
    /// ETag of the installed catalog, used for conditional (If-None-Match) updates.
    var catalogETag: String?

    init() {}

    /// Swift's synthesized decoder throws when a non-optional key is missing,
    /// even if the property has a default. Decode every key leniently so
    /// settings saved by an older build keep working after a field is added.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        onboardingCompleted = try c.decodeIfPresent(Bool.self, forKey: .onboardingCompleted) ?? false
        theme = try c.decodeIfPresent(OnqaTheme.self, forKey: .theme) ?? .dark
        accent = try c.decodeIfPresent(OnqaAccent.self, forKey: .accent) ?? .green
        useHQStream = try c.decodeIfPresent(Bool.self, forKey: .useHQStream) ?? true
        showLocationHeader = try c.decodeIfPresent(Bool.self, forKey: .showLocationHeader) ?? true
        locationSource = try c.decodeIfPresent(LocationSource.self, forKey: .locationSource) ?? .gps
        manualLatitude = try c.decodeIfPresent(Double.self, forKey: .manualLatitude)
        manualLongitude = try c.decodeIfPresent(Double.self, forKey: .manualLongitude)
        manualCity = try c.decodeIfPresent(String.self, forKey: .manualCity)
        manualCountryCode = try c.decodeIfPresent(String.self, forKey: .manualCountryCode)
        manualCityGeocodedAt = try c.decodeIfPresent(Date.self, forKey: .manualCityGeocodedAt)
        catalogUpdateFrequency = try c.decodeIfPresent(CatalogUpdateFrequency.self, forKey: .catalogUpdateFrequency) ?? .weekly
        lastCatalogUpdate = try c.decodeIfPresent(Date.self, forKey: .lastCatalogUpdate)
        catalogETag = try c.decodeIfPresent(String.self, forKey: .catalogETag)
    }
}

struct RadioStation: Identifiable, Hashable {
    var name: String
    var streamURL: String?
    var streamURLHQ: String?
    var logoURL: String?
    var transmitterName: String?
    var transmitterID: Int?
    var network: String?
    var distanceKm: Double?
    var displayOrder: Int
    var coverageKm: Double?
    var isFavorite = false

    var id: String { "\(name)|\(network ?? "")" }

    func streamURL(useHQ: Bool) -> URL? {
        let candidate = useHQ ? (streamURLHQ?.isEmpty == false ? streamURLHQ : streamURL) : (streamURL?.isEmpty == false ? streamURL : streamURLHQ)
        guard let candidate, let url = URL(string: candidate),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    func matches(url: URL?) -> Bool {
        guard let url else { return false }
        let value = url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return [streamURL, streamURLHQ].compactMap { $0 }.contains {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == value
        }
    }
}
struct FavoritesBackup: Codable {
    var favoriteStations: [String]
}
