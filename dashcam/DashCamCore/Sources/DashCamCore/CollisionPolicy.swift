import Foundation

/// Decides whether an accelerometer sample is a collision.
///
/// A sample triggers when its magnitude reaches `threshold`. After a trigger, further
/// samples are ignored for `debounceInterval` so that one impact (which produces many
/// consecutive over-threshold samples at 50 Hz) is reported exactly once.
///
/// Timestamps are the monotonic sensor timestamps (seconds), not wall-clock time,
/// which keeps the policy deterministic and independent of `Date()`.
public struct CollisionDetectionPolicy: Equatable, Sendable {
    public var threshold: Double
    public var debounceInterval: TimeInterval
    public private(set) var lastTriggerTimestamp: TimeInterval?

    public init(threshold: Double, debounceInterval: TimeInterval = 10) {
        self.threshold = threshold
        self.debounceInterval = debounceInterval
    }

    /// Magnitude of an acceleration vector in g. At rest this is about 1.0 because
    /// the accelerometer includes gravity.
    public static func magnitude(x: Double, y: Double, z: Double) -> Double {
        (x * x + y * y + z * z).squareRoot()
    }

    /// Returns `true` when this sample should raise a collision event.
    public mutating func evaluate(gForce: Double, timestamp: TimeInterval) -> Bool {
        guard gForce.isFinite, timestamp.isFinite, gForce >= threshold else { return false }
        if let last = lastTriggerTimestamp {
            let elapsed = timestamp - last
            // A negative delta means the clock restarted; treat that as a new epoch.
            if elapsed >= 0, elapsed < debounceInterval { return false }
        }
        lastTriggerTimestamp = timestamp
        return true
    }

    public mutating func reset() {
        lastTriggerTimestamp = nil
    }
}
