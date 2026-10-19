import Foundation

public struct DashcamConfig: Equatable, Sendable {
    public static let bufferMinutesRange = 15...360
    public static let collisionThresholdRange = 1.5...6.0

    public var resolution: VideoResolution
    public var frameRate: Int
    public var codec: VideoCodec
    /// Length of each recorded segment file in seconds.
    public var segmentDuration: TimeInterval
    /// Length of the rolling loop in minutes (15 to 360).
    public var bufferMinutes: Int
    /// Acceleration magnitude in g that counts as a collision.
    public var collisionThreshold: Double
    public var accelerometerUpdateInterval: TimeInterval

    public init(
        resolution: VideoResolution = .hd720p,
        frameRate: Int = 30,
        codec: VideoCodec = .hevc,
        segmentDuration: TimeInterval = 60,
        bufferMinutes: Int = 15,
        collisionThreshold: Double = 3.0,
        accelerometerUpdateInterval: TimeInterval = 1.0 / 50.0
    ) {
        self.resolution = resolution
        self.frameRate = frameRate
        self.codec = codec
        self.segmentDuration = segmentDuration
        self.bufferMinutes = bufferMinutes
        self.collisionThreshold = collisionThreshold
        self.accelerometerUpdateInterval = accelerometerUpdateInterval
    }

    public var maxBufferDuration: TimeInterval {
        TimeInterval(bufferMinutes) * 60
    }

    /// Number of segments kept in the rolling buffer.
    public var maxSegments: Int {
        LoopBufferPolicy.maxSegments(bufferDuration: maxBufferDuration, segmentDuration: segmentDuration)
    }

    /// Estimated disk usage of a full buffer, in bytes.
    public var estimatedBufferBytes: Int64 {
        VideoQuality.estimatedBytes(duration: maxBufferDuration, resolution: resolution, codec: codec)
    }

    // MARK: - Persistence

    static let bufferMinutesKey = "dashcam_bufferMinutes"
    static let collisionThresholdKey = "dashcam_collisionThreshold"

    /// Loads user-adjustable settings; out-of-range or missing values fall back to defaults.
    public static func load(from defaults: UserDefaults = .standard) -> DashcamConfig {
        var config = DashcamConfig()
        let minutes = defaults.integer(forKey: bufferMinutesKey)
        if bufferMinutesRange.contains(minutes) {
            config.bufferMinutes = minutes
        }
        let threshold = defaults.double(forKey: collisionThresholdKey)
        if collisionThresholdRange.contains(threshold) {
            config.collisionThreshold = threshold
        }
        return config
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(bufferMinutes, forKey: Self.bufferMinutesKey)
        defaults.set(collisionThreshold, forKey: Self.collisionThresholdKey)
    }
}

/// Loop durations offered in Settings.
public enum BufferDurationOption: Int, CaseIterable, Identifiable, Sendable {
    case min15 = 15
    case min30 = 30
    case hr1 = 60
    case hr2 = 120
    case hr3 = 180
    case hr6 = 360

    public var id: Int { rawValue }
}
