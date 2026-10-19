import Foundation

/// A file in one of the app's storage directories, reduced to what the policy needs.
public struct StoredFile: Equatable, Sendable {
    public var name: String
    public var modificationDate: Date
    public var size: Int64

    public init(name: String, modificationDate: Date, size: Int64) {
        self.name = name
        self.modificationDate = modificationDate
        self.size = size
    }
}

/// Free-space thresholds and cleanup decisions for the on-disk loop buffer.
public struct StoragePolicy: Equatable, Sendable {
    /// Below this the HUD shows a low-storage warning.
    public var lowStorageThresholdBytes: Int64
    /// Free space the buffer must not eat into. When free space drops below it,
    /// the loop is shortened (oldest footage is dropped first).
    public var reserveBytes: Int64
    /// The loop is never shortened below this many segments.
    public var minimumSegments: Int

    public static let gibibyte: Int64 = 1_073_741_824
    public static let mebibyte: Int64 = 1_048_576

    public init(
        lowStorageThresholdBytes: Int64 = StoragePolicy.gibibyte,
        reserveBytes: Int64 = 512 * StoragePolicy.mebibyte,
        minimumSegments: Int = 2
    ) {
        self.lowStorageThresholdBytes = lowStorageThresholdBytes
        self.reserveBytes = reserveBytes
        self.minimumSegments = max(1, minimumSegments)
    }

    public func isLow(freeBytes: Int64) -> Bool {
        freeBytes < lowStorageThresholdBytes
    }

    /// How many segments the loop may currently hold given the free disk space.
    ///
    /// Returns `configuredMax` when there is enough free space. Otherwise it
    /// estimates the average segment size from what is on disk and returns the
    /// count that frees up the shortfall, clamped to `minimumSegments...configuredMax`.
    public func allowedSegments(
        configuredMax: Int,
        currentCount: Int,
        bufferBytes: Int64,
        freeBytes: Int64
    ) -> Int {
        let configured = max(1, configuredMax)
        guard freeBytes < reserveBytes, currentCount > 0, bufferBytes > 0 else { return configured }

        let shortfall = Double(reserveBytes - freeBytes)
        let averageSegmentBytes = Double(bufferBytes) / Double(currentCount)
        let toDrop = Int((shortfall / averageSegmentBytes).rounded(.up))
        let allowed = max(min(minimumSegments, configured), currentCount - toDrop)
        return min(configured, allowed)
    }

    /// Segment files that are no longer referenced by the buffer and are safe to delete.
    ///
    /// Only files that look like segments (see `SegmentNaming`) and are not tracked are
    /// returned. Files modified at or after `cutoff` are kept: they may belong to a
    /// recording that started in the current session.
    public func orphanedSegmentFiles(
        in files: [StoredFile],
        trackedFilenames: Set<String>,
        cutoff: Date,
        timeZone: TimeZone = .current
    ) -> [StoredFile] {
        files.filter { file in
            SegmentNaming.isSegmentFilename(file.name, timeZone: timeZone)
                && !trackedFilenames.contains(file.name)
                && file.modificationDate < cutoff
        }
    }
}
