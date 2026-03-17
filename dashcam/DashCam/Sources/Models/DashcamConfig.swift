import Foundation

struct DashcamConfig {
    var resolution: VideoResolution = .hd720p
    var frameRate: Int = 30
    var codec: VideoCodec = .hevc
    var segmentDuration: TimeInterval = 60 // 1 minute per segment
    var bufferMinutes: Int = 15 // user-configurable: 15 to 360
    var collisionThreshold: Double = 3.0 // g-force
    var accelerometerUpdateInterval: TimeInterval = 1.0 / 50.0 // 50 Hz

    /// Number of 1-minute segments to keep in the rolling buffer.
    var maxSegments: Int { bufferMinutes }

    var maxBufferDuration: TimeInterval {
        segmentDuration * Double(maxSegments)
    }

    // MARK: - Persistence

    private static let bufferMinutesKey = "dashcam_bufferMinutes"
    private static let collisionThresholdKey = "dashcam_collisionThreshold"

    static func load() -> DashcamConfig {
        var config = DashcamConfig()
        let defaults = UserDefaults.standard
        let saved = defaults.integer(forKey: bufferMinutesKey)
        if saved >= 15 && saved <= 360 {
            config.bufferMinutes = saved
        }
        let threshold = defaults.double(forKey: collisionThresholdKey)
        if threshold >= 1.5 && threshold <= 6.0 {
            config.collisionThreshold = threshold
        }
        return config
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(bufferMinutes, forKey: Self.bufferMinutesKey)
        defaults.set(collisionThreshold, forKey: Self.collisionThresholdKey)
    }
}

// MARK: - Supporting Types

enum BufferDurationOption: Int, CaseIterable, Identifiable {
    case min15 = 15
    case min30 = 30
    case hr1 = 60
    case hr2 = 120
    case hr3 = 180
    case hr6 = 360

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .min15: return NSLocalizedString("buffer.15min", comment: "")
        case .min30: return NSLocalizedString("buffer.30min", comment: "")
        case .hr1: return NSLocalizedString("buffer.1hr", comment: "")
        case .hr2: return NSLocalizedString("buffer.2hr", comment: "")
        case .hr3: return NSLocalizedString("buffer.3hr", comment: "")
        case .hr6: return NSLocalizedString("buffer.6hr", comment: "")
        }
    }
}

enum VideoResolution: String, CaseIterable {
    case hd720p = "720p"
    case hd1080p = "1080p"

    var width: Int {
        switch self {
        case .hd720p: return 1280
        case .hd1080p: return 1920
        }
    }

    var height: Int {
        switch self {
        case .hd720p: return 720
        case .hd1080p: return 1080
        }
    }
}

enum VideoCodec: String, CaseIterable {
    case hevc = "HEVC"
    case h264 = "H.264"
}

enum RecordingState: Equatable {
    case idle
    case recording
    case paused
    case error(String)

    static func == (lhs: RecordingState, rhs: RecordingState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.recording, .recording), (.paused, .paused):
            return true
        case (.error(let a), .error(let b)):
            return a == b
        default:
            return false
        }
    }
}
