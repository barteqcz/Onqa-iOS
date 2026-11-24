import Foundation

enum RetryBackoff {

    static func delay(
        afterFailures failures: Int,
        base: TimeInterval,
        cap: TimeInterval
    ) -> TimeInterval {
        guard failures > 0 else { return 0 }

        let exponent = min(failures - 1, 30)
        return min(cap, base * pow(2, Double(exponent)))
    }
}

enum StreamMetadata {

    private static let trackTitleIdentifiers: Set<String> = [
        "icy/StreamTitle",
        "common/title",
        "id3/TIT2"
    ]

    static func isTrackTitle(identifier: String?) -> Bool {
        guard let identifier else { return false }
        return trackTitleIdentifiers.contains(identifier)
    }
}
