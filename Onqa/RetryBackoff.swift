import Foundation

/// Exponential backoff used wherever the app retries something that can keep
/// failing for a long time (stream reconnects, reverse geocoding), so a
/// persistent failure never turns into a tight retry loop.
enum RetryBackoff {
    /// Delay to wait after `failures` consecutive failures: `base`, then
    /// 2 x `base`, 4 x `base`, ... never more than `cap`. Zero failures means
    /// no delay.
    static func delay(
        afterFailures failures: Int,
        base: TimeInterval,
        cap: TimeInterval
    ) -> TimeInterval {
        guard failures > 0 else { return 0 }
        // Clamp the exponent so a very long outage cannot overflow the shift.
        let exponent = min(failures - 1, 30)
        return min(cap, base * pow(2, Double(exponent)))
    }
}

/// Decides which timed-metadata items carry the currently playing track title.
/// Streams publish several string items (title, station name, URL, genre ...),
/// and only the title should reach the mini player and Now Playing.
enum StreamMetadata {
    /// Raw values of AVMetadataIdentifier.icyMetadataStreamTitle,
    /// .commonIdentifierTitle and .id3MetadataTitleDescription.
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
