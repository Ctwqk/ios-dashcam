import Foundation

struct Segment: Identifiable, Codable {
    let id: UUID
    let filename: String
    let startTime: Date
    var endTime: Date?
    var isProtected: Bool

    var duration: TimeInterval? {
        guard let endTime else { return nil }
        return endTime.timeIntervalSince(startTime)
    }

    var url: URL {
        let dir = isProtected
            ? FileProtectionManager.protectedDirectory
            : LoopBufferManager.segmentsDirectory
        return dir.appendingPathComponent(filename)
    }

    init(startTime: Date = Date()) {
        self.id = UUID()
        self.filename = "seg_\(Self.formatter.string(from: startTime))_\(id.uuidString.prefix(8)).mp4"
        self.startTime = startTime
        self.endTime = nil
        self.isProtected = false
    }

    /// Restore a segment from an existing file on disk.
    init(existingFilename: String, startTime: Date, isProtected: Bool) {
        self.id = UUID()
        self.filename = existingFilename
        self.startTime = startTime
        self.endTime = nil
        self.isProtected = isProtected
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f
    }()
}
