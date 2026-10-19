import os

/// Central `os.Logger` instances. Use these instead of `print` so output is
/// filterable in Console.app and costs nothing in release builds.
enum Log {
    private static let subsystem = "com.constructure.dashcam"

    static let camera = Logger(subsystem: subsystem, category: "camera")
    static let recording = Logger(subsystem: subsystem, category: "recording")
    static let storage = Logger(subsystem: subsystem, category: "storage")
    static let location = Logger(subsystem: subsystem, category: "location")
}
