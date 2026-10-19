import Foundation

/// Rolling buffer of the most recent segments.
///
/// This is the pure bookkeeping behind loop recording: it decides which segments
/// fall off the back of the loop, and it never touches the file system. Every
/// mutating call returns the segments whose files may be deleted *right now*.
///
/// Segments can be *held* while they are being exported (merged and saved to
/// Photos). A held segment that is evicted is removed from the buffer
/// immediately, but its file is only reported as deletable once the last hold on
/// it is released, so an export never has its input files deleted from under it.
/// Holds are counted, so overlapping exports are safe.
public struct LoopBuffer: Equatable, Sendable {
    public private(set) var segments: [Segment] = []
    public private(set) var maxSegments: Int

    private var holdCounts: [UUID: Int] = [:]
    private var deferredDeletion: [Segment] = []

    public init(maxSegments: Int) {
        self.maxSegments = max(1, maxSegments)
    }

    /// Sum of the durations of all finished segments.
    public var totalDuration: TimeInterval {
        segments.compactMap(\.duration).reduce(0, +)
    }

    /// Appends the newest segment and evicts the oldest ones beyond the limit.
    @discardableResult
    public mutating func append(_ segment: Segment) -> [Segment] {
        segments.append(segment)
        return evictOverflow()
    }

    /// Changes the loop length. Shrinking evicts the oldest segments.
    @discardableResult
    public mutating func setMaxSegments(_ value: Int) -> [Segment] {
        maxSegments = max(1, value)
        return evictOverflow()
    }

    /// Empties the buffer.
    @discardableResult
    public mutating func removeAll() -> [Segment] {
        let removed = segments
        segments.removeAll()
        return splitHeld(removed)
    }

    /// Protects the given segments' files from deletion until `release(_:)`.
    public mutating func hold(_ ids: [UUID]) {
        for id in ids {
            holdCounts[id, default: 0] += 1
        }
    }

    /// Drops one hold on each of `ids` and returns evicted segments whose files
    /// are no longer held and can now be deleted.
    @discardableResult
    public mutating func release(_ ids: [UUID]) -> [Segment] {
        for id in ids {
            guard let count = holdCounts[id] else { continue }
            holdCounts[id] = count > 1 ? count - 1 : nil
        }
        let ready = deferredDeletion.filter { holdCounts[$0.id] == nil }
        deferredDeletion.removeAll { holdCounts[$0.id] == nil }
        return ready
    }

    // MARK: - Private

    private mutating func evictOverflow() -> [Segment] {
        guard segments.count > maxSegments else { return [] }
        let overflow = segments.count - maxSegments
        let evicted = Array(segments.prefix(overflow))
        segments.removeFirst(overflow)
        return splitHeld(evicted)
    }

    /// Returns the segments that are not held; defers the held ones.
    private mutating func splitHeld(_ candidates: [Segment]) -> [Segment] {
        var deletable: [Segment] = []
        for segment in candidates {
            if holdCounts[segment.id] != nil {
                deferredDeletion.append(segment)
            } else {
                deletable.append(segment)
            }
        }
        return deletable
    }
}
