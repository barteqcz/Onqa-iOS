import os

/// Central `os.Logger` categories. Messages never include coordinates or other
/// personal data; use `privacy: .public` only for non-sensitive text.
enum Log {
    private static let subsystem = "com.barteqcz.onqa"

    static let catalog = Logger(subsystem: subsystem, category: "catalog")
    static let playback = Logger(subsystem: subsystem, category: "playback")
    static let location = Logger(subsystem: subsystem, category: "location")
}
