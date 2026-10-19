import Foundation

/// How many fixed-length segments are needed to cover a loop duration.
public enum LoopBufferPolicy {
    /// Number of segments required to hold `bufferDuration` seconds of footage.
    /// Always at least 1; a partial trailing segment is rounded up.
    public static func maxSegments(bufferDuration: TimeInterval, segmentDuration: TimeInterval) -> Int {
        guard bufferDuration > 0, segmentDuration > 0 else { return 1 }
        return max(1, Int((bufferDuration / segmentDuration).rounded(.up)))
    }
}
