import Foundation

/// Describes an exported clip (the merged contents of the buffer) that is saved to Photos.
public struct ClipMetadata: Equatable, Sendable {
    public enum Trigger: String, Sendable {
        case manual
        case collision
    }

    public var trigger: Trigger
    /// Start of the earliest segment in the clip.
    public var startDate: Date
    public var segmentCount: Int
    /// Combined duration of all finished segments in the clip.
    public var duration: TimeInterval
    public var id: UUID

    public init(
        trigger: Trigger,
        startDate: Date,
        segmentCount: Int,
        duration: TimeInterval,
        id: UUID = UUID()
    ) {
        self.trigger = trigger
        self.startDate = startDate
        self.segmentCount = segmentCount
        self.duration = duration
        self.id = id
    }

    /// Builds metadata for a clip made of `segments`, or `nil` if there are none.
    public static func make(trigger: Trigger, segments: [Segment], id: UUID = UUID()) -> ClipMetadata? {
        guard let first = segments.map(\.startTime).min() else { return nil }
        let duration = segments.compactMap(\.duration).reduce(0, +)
        return ClipMetadata(trigger: trigger, startDate: first, segmentCount: segments.count, duration: duration, id: id)
    }

    public func filename(timeZone: TimeZone = .current) -> String {
        SegmentNaming.exportFilename(label: trigger.rawValue, date: startDate, id: id, timeZone: timeZone)
    }
}

/// Unit conversion for location speed readings.
public enum SpeedConversion {
    /// Converts m/s to km/h. Core Location reports an invalid speed as a negative
    /// number; that, and non-finite values, map to 0.
    public static func kilometersPerHour(metersPerSecond: Double) -> Double {
        guard metersPerSecond.isFinite, metersPerSecond > 0 else { return 0 }
        return metersPerSecond * 3.6
    }
}
