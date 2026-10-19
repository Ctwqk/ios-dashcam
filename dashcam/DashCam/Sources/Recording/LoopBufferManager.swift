import Foundation
import Combine
import DashCamCore

/// Owns the on-disk side of the rolling buffer: it records which segment files exist,
/// deletes the ones that fall off the loop, and hands out export snapshots.
///
/// All eviction decisions are made by `LoopBuffer` / `StoragePolicy` in DashCamCore.
/// Every method must be called on the main thread; file deletion happens on a
/// background queue.
final class LoopBufferManager: ObservableObject {
    static var segmentsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("dashcam/segments")
    }

    /// A consistent snapshot of the buffer taken for saving to Photos. The files in it are
    /// protected from deletion until `endExport(_:clearBuffer:)` is called.
    struct ExportRequest {
        let segmentIDs: [UUID]
        let fileURLs: [URL]
        let metadata: ClipMetadata
    }

    @Published private(set) var segments: [Segment] = []
    @Published private(set) var totalBufferDuration: TimeInterval = 0

    private var buffer: LoopBuffer
    private var configuredMaxSegments: Int
    private let directory: URL
    private let storagePolicy: StoragePolicy
    private let fileManager = FileManager.default

    /// Background queue for all file I/O (delete, create directory, etc.)
    private let ioQueue = DispatchQueue(label: "com.dashcam.loopbuffer.io", qos: .utility)

    init(
        config: DashcamConfig,
        directory: URL = LoopBufferManager.segmentsDirectory,
        storagePolicy: StoragePolicy = StoragePolicy()
    ) {
        self.buffer = LoopBuffer(maxSegments: config.maxSegments)
        self.configuredMaxSegments = config.maxSegments
        self.directory = directory
        self.storagePolicy = storagePolicy

        let launchDate = Date()
        ioQueue.async { [weak self] in
            self?.prepareDirectory(launchDate: launchDate)
        }
    }

    // MARK: - Loop

    func updateMaxSegments(_ max: Int) {
        configuredMaxSegments = max
        delete(buffer.setMaxSegments(max))
        publish()
    }

    func addSegment(_ segment: Segment) {
        delete(buffer.append(segment))
        publish()
    }

    /// Shortens the loop when the disk is nearly full (and restores it when space frees up).
    func enforceQuota(freeBytes: Int64, bufferBytes: Int64) {
        let allowed = storagePolicy.allowedSegments(
            configuredMax: configuredMaxSegments,
            currentCount: buffer.segments.count,
            bufferBytes: bufferBytes,
            freeBytes: freeBytes
        )
        guard allowed != buffer.maxSegments else { return }
        Log.storage.notice("adjusting loop to \(allowed) segments (free \(freeBytes) bytes)")
        delete(buffer.setMaxSegments(allowed))
        publish()
    }

    /// Delete all buffer segment files and clear the list.
    func discardAllSegments() {
        delete(buffer.removeAll())
        publish()
    }

    // MARK: - Export

    /// Snapshots the segments that currently exist on disk and protects them from deletion.
    func beginExport(trigger: ClipMetadata.Trigger) -> ExportRequest? {
        let available = buffer.segments.filter { fileManager.fileExists(atPath: url(for: $0).path) }
        guard let metadata = ClipMetadata.make(trigger: trigger, segments: available) else { return nil }
        let ids = available.map(\.id)
        buffer.hold(ids)
        return ExportRequest(segmentIDs: ids, fileURLs: available.map(url(for:)), metadata: metadata)
    }

    /// Releases an export snapshot. With `clearBuffer`, the buffer is emptied as well
    /// (used after a successful manual save).
    func endExport(_ request: ExportRequest, clearBuffer: Bool) {
        if clearBuffer {
            delete(buffer.removeAll())
        }
        delete(buffer.release(request.segmentIDs))
        publish()
    }

    // MARK: - Private

    private func url(for segment: Segment) -> URL {
        directory.appendingPathComponent(segment.filename)
    }

    private func publish() {
        segments = buffer.segments
        totalBufferDuration = buffer.totalDuration
    }

    private func delete(_ evicted: [Segment]) {
        guard !evicted.isEmpty else { return }
        let urls = evicted.map(url(for:))
        ioQueue.async { [fileManager] in
            for url in urls {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    /// Creates the directory and removes segment files left behind by an earlier session
    /// (crash, force quit, failed save). They are not part of this session's buffer, so
    /// without this they would occupy disk space forever.
    private func prepareDirectory(launchDate: Date) {
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return }

        let files = urls.map { url -> StoredFile in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return StoredFile(
                name: url.lastPathComponent,
                modificationDate: values?.contentModificationDate ?? .distantPast,
                size: Int64(values?.fileSize ?? 0)
            )
        }

        let orphans = storagePolicy.orphanedSegmentFiles(in: files, trackedFilenames: [], cutoff: launchDate)
        for orphan in orphans {
            try? fileManager.removeItem(at: directory.appendingPathComponent(orphan.name))
        }
        if !orphans.isEmpty {
            Log.storage.notice("removed \(orphans.count) leftover segment file(s) from a previous session")
        }
    }
}
