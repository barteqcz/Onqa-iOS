import Foundation
import CoreLocation

enum StationProcessor {
    static func distanceKm(from latitude: Double, longitude: Double, to otherLatitude: Double, longitude otherLongitude: Double) -> Double {
        let origin = CLLocation(latitude: latitude, longitude: longitude)
        let destination = CLLocation(latitude: otherLatitude, longitude: otherLongitude)
        return origin.distance(from: destination) / 1_000
    }

    /// Returns true when a new coordinate is at least the requested distance
    /// from the last accepted coordinate.
    static func hasMoved(
        atLeast thresholdKm: Double,
        from coordinate: CLLocationCoordinate2D,
        to otherCoordinate: CLLocationCoordinate2D
    ) -> Bool {
        distanceKm(
            from: coordinate.latitude,
            longitude: coordinate.longitude,
            to: otherCoordinate.latitude,
            longitude: otherCoordinate.longitude
        ) >= thresholdKm
    }

    /// Accept the initial fix, then process coordinate changes only after
    /// the listener has moved by at least the configured distance.
    /// Reverse-geocoding retries are handled separately from station updates.
    static func shouldProcessLocationUpdate(
        from previousCoordinate: CLLocationCoordinate2D?,
        to coordinate: CLLocationCoordinate2D,
        thresholdKm: Double
    ) -> Bool {
        guard let previousCoordinate else { return true }
        return hasMoved(atLeast: thresholdKm, from: previousCoordinate, to: coordinate)
    }

    static func groupAndSort(_ allStations: [RadioStation], favorites: Set<String>) -> [RadioStation] {
        var representatives: [String: RadioStation] = [:]
        for station in allStations {
            let isZeroCoverage = station.coverageKm.map { $0 <= 0 } ?? false
            let outsideCoverage: Bool
            if let distance = station.distanceKm, let coverage = station.coverageKm {
                outsideCoverage = distance > coverage
            } else {
                outsideCoverage = false
            }
            guard !isZeroCoverage && !outsideCoverage else { continue }

            if let existing = representatives[station.id] {
                let oldDistance = existing.distanceKm ?? .greatestFiniteMagnitude
                let newDistance = station.distanceKm ?? .greatestFiniteMagnitude
                if newDistance < oldDistance
                    || (newDistance == oldDistance && station.displayOrder < existing.displayOrder) {
                    representatives[station.id] = station
                }
            } else {
                representatives[station.id] = station
            }
        }

        return representatives.values.map { station in
            var value = station
            value.isFavorite = favorites.contains(station.id)
            return value
        }.sorted {
            if $0.isFavorite != $1.isFavorite { return $0.isFavorite }
            let left = $0.distanceKm ?? .greatestFiniteMagnitude
            let right = $1.distanceKm ?? .greatestFiniteMagnitude
            if left != right { return left < right }
            if $0.transmitterID != $1.transmitterID {
                return ($0.transmitterID ?? .max) < ($1.transmitterID ?? .max)
            }
            return $0.displayOrder < $1.displayOrder
        }
    }
}
