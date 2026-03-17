import Foundation
import Combine

final class LoopBufferManager: ObservableObject {
    static var segmentsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("dashcam/segments")
    }

    @Published private(set) var segments: [Segment] = []
    @Published private(set) var totalBufferDuration: TimeInterval = 0

    private var config: DashcamConfig
    private let fileManager = FileManager.default

    /// Background queue for all file I/O (delete, create directory, etc.)
    private let ioQueue = DispatchQueue(label: "com.dashcam.loopbuffer.io", qos: .utility)

    init(config: DashcamConfig) {
        self.config = config
        ioQueue.async { [weak self] in
            self?.ensureDirectories()
        }
    }

    func updateMaxSegments(_ max: Int) {
        config.bufferMinutes = max
        pruneOldSegments()
    }

    func addSegment(_ segment: Segment) {
        segments.append(segment)
        recalculateDuration()
        pruneOldSegments()
    }

    /// Returns file URLs for all current buffer segments (in chronological order).
    /// Buffer stays intact. Used to gather files for merging.
    func allSegmentFileURLs() -> [URL] {
        segments.map { Self.segmentsDirectory.appendingPathComponent($0.filename) }
            .filter { fileManager.fileExists(atPath: $0.path) }
    }

    /// Delete all buffer segment files and clear the list.
    func discardAllSegments() {
        let urls = segments.map { Self.segmentsDirectory.appendingPathComponent($0.filename) }
        segments.removeAll()
        recalculateDuration()
        ioQueue.async { [fileManager] in
            for url in urls {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    /// Remove all segments from buffer and delete their files.
    /// Called after manual save has successfully merged and saved to Photos.
    func clearBuffer() {
        discardAllSegments()
    }

    // MARK: - Private

    private func pruneOldSegments() {
        var removed: [URL] = []
        while segments.count > config.maxSegments {
            let oldest = segments.removeFirst()
            removed.append(Self.segmentsDirectory.appendingPathComponent(oldest.filename))
        }
        recalculateDuration()
        if !removed.isEmpty {
            ioQueue.async { [fileManager] in
                for url in removed {
                    try? fileManager.removeItem(at: url)
                }
            }
        }
    }

    private func recalculateDuration() {
        totalBufferDuration = segments.compactMap(\.duration).reduce(0, +)
    }

    private func ensureDirectories() {
        try? fileManager.createDirectory(
            at: Self.segmentsDirectory,
            withIntermediateDirectories: true
        )
    }
}
