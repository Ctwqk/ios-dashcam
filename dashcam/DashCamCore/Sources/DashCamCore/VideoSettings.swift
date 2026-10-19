import Foundation

public enum VideoResolution: String, CaseIterable, Codable, Sendable {
    case hd720p = "720p"
    case hd1080p = "1080p"

    public var width: Int {
        switch self {
        case .hd720p: return 1280
        case .hd1080p: return 1920
        }
    }

    public var height: Int {
        switch self {
        case .hd720p: return 720
        case .hd1080p: return 1080
        }
    }
}

public enum VideoCodec: String, CaseIterable, Codable, Sendable {
    case hevc = "HEVC"
    case h264 = "H.264"
}

/// Target encoder bit rates. They are applied to the `AVAssetWriter` video input
/// and are also used to estimate how much disk a given loop duration needs, so the
/// estimate shown in Settings matches what the encoder is actually asked to do.
public enum VideoQuality {
    public static let audioBitRate = 64_000

    /// Average video bit rate in bits per second.
    public static func videoBitRate(resolution: VideoResolution, codec: VideoCodec) -> Int {
        switch (resolution, codec) {
        case (.hd720p, .hevc): return 2_500_000
        case (.hd720p, .h264): return 4_000_000
        case (.hd1080p, .hevc): return 5_000_000
        case (.hd1080p, .h264): return 8_000_000
        }
    }

    /// Estimated size of footage (video + audio) of the given duration, in bytes.
    public static func estimatedBytes(
        duration: TimeInterval,
        resolution: VideoResolution,
        codec: VideoCodec
    ) -> Int64 {
        guard duration > 0 else { return 0 }
        let bitsPerSecond = Double(videoBitRate(resolution: resolution, codec: codec) + audioBitRate)
        return Int64((bitsPerSecond / 8.0 * duration).rounded())
    }
}

/// Device thermal pressure, mirroring `ProcessInfo.ThermalState` (which is not
/// available outside Apple platforms, and not constructible in tests).
public enum ThermalLevel: Int, CaseIterable, Sendable {
    case nominal
    case fair
    case serious
    case critical
}

/// Frame-rate throttling under thermal pressure.
public enum ThermalPolicy {
    public static let minimumThrottledFrameRate = 15

    /// Returns the frame rate to capture at for a given thermal level.
    /// The result never exceeds the configured `baseFrameRate`.
    public static func targetFrameRate(baseFrameRate: Int, thermalLevel: ThermalLevel) -> Int {
        let base = max(1, baseFrameRate)
        switch thermalLevel {
        case .nominal, .fair:
            return base
        case .serious:
            return min(base, max(minimumThrottledFrameRate, base / 2))
        case .critical:
            return min(base, minimumThrottledFrameRate)
        }
    }
}
