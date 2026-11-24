import os

 
 
enum Log {
    private static let subsystem = "com.barteqcz.onqa"

    static let catalog = Logger(subsystem: subsystem, category: "catalog")
    static let playback = Logger(subsystem: subsystem, category: "playback")
    static let location = Logger(subsystem: subsystem, category: "location")
}
