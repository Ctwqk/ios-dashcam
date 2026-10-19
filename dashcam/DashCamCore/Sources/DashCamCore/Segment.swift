import Foundation

/// One recorded file of the rolling buffer.
public struct Segment: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let filename: String
    public let startTime: Date
    public var endTime: Date?
    public var isProtected: Bool

    public var duration: TimeInterval? {
        guard let endTime else { return nil }
        return max(0, endTime.timeIntervalSince(startTime))
    }

    /// A new segment that starts at `startTime`; the file name is derived from it.
    public init(startTime: Date = Date(), id: UUID = UUID(), timeZone: TimeZone = .current) {
        self.id = id
        self.filename = SegmentNaming.segmentFilename(startTime: startTime, id: id, timeZone: timeZone)
        self.startTime = startTime
        self.endTime = nil
        self.isProtected = false
    }

    /// Restore a segment from an existing file on disk.
    public init(existingFilename: String, startTime: Date, isProtected: Bool, id: UUID = UUID()) {
        self.id = id
        self.filename = existingFilename
        self.startTime = startTime
        self.endTime = nil
        self.isProtected = isProtected
    }
}
