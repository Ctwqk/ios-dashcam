import CoreMotion
import Combine
import DashCamCore

/// Streams accelerometer samples and raises `onCollisionDetected` on impacts.
///
/// The threshold/debounce decision lives in `CollisionDetectionPolicy` (DashCamCore,
/// unit tested); this class only owns the sensor and the threading.
final class CollisionDetector: ObservableObject {
    @Published private(set) var currentGForce: Double = 0
    @Published private(set) var isMonitoring = false
    @Published private(set) var lastCollisionDate: Date?

    var onCollisionDetected: (() -> Void)?

    private let motionManager = CMMotionManager()
    private let operationQueue = OperationQueue()
    private let updateInterval: TimeInterval

    /// The policy is mutated from the sensor queue (evaluate) and the main thread
    /// (threshold changes from Settings), so it is guarded by a lock.
    private let policyLock = NSLock()
    private var policy: CollisionDetectionPolicy

    /// Only touched on `operationQueue`.
    private var lastPublishedTimestamp: TimeInterval = -.infinity

    /// The HUD shows one decimal place, so there is no point re-rendering SwiftUI at 50 Hz.
    private static let hudRefreshInterval: TimeInterval = 0.2

    init(config: DashcamConfig) {
        self.updateInterval = config.accelerometerUpdateInterval
        self.policy = CollisionDetectionPolicy(threshold: config.collisionThreshold)
        operationQueue.name = "com.dashcam.collision"
        operationQueue.maxConcurrentOperationCount = 1
    }

    /// Applies a new sensitivity immediately, including while monitoring.
    func updateThreshold(_ threshold: Double) {
        policyLock.withLock { policy.threshold = threshold }
    }

    func startMonitoring() {
        guard motionManager.isAccelerometerAvailable, !isMonitoring else { return }

        policyLock.withLock { policy.reset() }
        motionManager.accelerometerUpdateInterval = updateInterval
        isMonitoring = true

        motionManager.startAccelerometerUpdates(to: operationQueue) { [weak self] data, _ in
            guard let self, let data else { return }
            self.process(data)
        }
    }

    func stopMonitoring() {
        motionManager.stopAccelerometerUpdates()
        isMonitoring = false
    }

    // MARK: - Private (runs on operationQueue)

    private func process(_ data: CMAccelerometerData) {
        let acceleration = data.acceleration
        let gForce = CollisionDetectionPolicy.magnitude(x: acceleration.x, y: acceleration.y, z: acceleration.z)

        if data.timestamp - lastPublishedTimestamp >= Self.hudRefreshInterval {
            lastPublishedTimestamp = data.timestamp
            DispatchQueue.main.async { [weak self] in
                self?.currentGForce = gForce
            }
        }

        let isCollision = policyLock.withLock {
            policy.evaluate(gForce: gForce, timestamp: data.timestamp)
        }
        guard isCollision else { return }

        DispatchQueue.main.async { [weak self] in
            self?.lastCollisionDate = Date()
            self?.onCollisionDetected?()
        }
    }

    deinit {
        motionManager.stopAccelerometerUpdates()
    }
}
