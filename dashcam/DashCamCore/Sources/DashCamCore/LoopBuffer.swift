import Foundation

/// Rolling buffer of the most recent segments.
///
/// This is the pure bookkeeping behind loop recording: it decides which segments
/// fall off the back of the loop, and it never touches the file system. Every
/// mutating call returns the segments whose files may be deleted *right now*.
///
/// Segments can be *held* while they are being exported (merged and saved to
/// Photos). A held segment that is evicted is removed from the buffer
/// immediately, but its file is only reported as deletable by `releaseHold()`,
/// so an export never has its input files deleted from under it.
public struct LoopBuffer: Equatable, Sendable {
    public private(set) var segments: [Segment] = []
    public private(set) var maxSegments: Int

    private var heldIDs = Set<UUID>()
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

    /// Protects the given segments' files from deletion until `releaseHold()`.
    public mutating func hold(_ ids: [UUID]) {
        heldIDs.formUnion(ids)
    }

    /// Ends the hold and returns evicted segments whose deletion was deferred.
    @discardableResult
    public mutating func releaseHold() -> [Segment] {
        heldIDs.removeAll()
        let pending = deferredDeletion
        deferredDeletion.removeAll()
        return pending
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
            if heldIDs.contains(segment.id) {
                deferredDeletion.append(segment)
            } else {
                deletable.append(segment)
            }
        }
        return deletable
    }
}
