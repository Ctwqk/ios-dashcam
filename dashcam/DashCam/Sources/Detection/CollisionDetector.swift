import CoreMotion
import Combine

final class CollisionDetector: ObservableObject {
    @Published private(set) var currentGForce: Double = 0
    @Published private(set) var isMonitoring = false
    @Published private(set) var lastCollisionDate: Date?

    var onCollisionDetected: (() -> Void)?

    private let motionManager = CMMotionManager()
    private let config: DashcamConfig
    private let operationQueue = OperationQueue()

    init(config: DashcamConfig) {
        self.config = config
        operationQueue.name = "com.dashcam.collision"
        operationQueue.maxConcurrentOperationCount = 1
    }

    func startMonitoring() {
        guard motionManager.isAccelerometerAvailable, !isMonitoring else { return }

        motionManager.accelerometerUpdateInterval = config.accelerometerUpdateInterval
        isMonitoring = true

        motionManager.startAccelerometerUpdates(to: operationQueue) { [weak self] data, _ in
            guard let self, let data else { return }

            let accel = data.acceleration
            let totalG = sqrt(accel.x * accel.x + accel.y * accel.y + accel.z * accel.z)

            DispatchQueue.main.async {
                self.currentGForce = totalG
            }

            if totalG >= self.config.collisionThreshold {
                self.triggerCollision()
            }
        }
    }

    func stopMonitoring() {
        motionManager.stopAccelerometerUpdates()
        isMonitoring = false
    }

    // MARK: - Private

    private func triggerCollision() {
        // Debounce: ignore collisions within 10 seconds of each other
        if let last = lastCollisionDate, Date().timeIntervalSince(last) < 10 {
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.lastCollisionDate = Date()
            self?.onCollisionDetected?()
        }
    }

    deinit {
        stopMonitoring()
    }
}
