import SwiftUI
import UIKit
import Combine
import CoreLocation
import DashCamCore

@MainActor
final class DashcamViewModel: ObservableObject {
    // MARK: - Published State

    @Published var recordingState: RecordingState = .idle
    @Published var config: DashcamConfig
    @Published var currentSpeed: Double = 0 // km/h
    @Published var isLocationDenied = false
    @Published var currentGForce: Double = 0
    @Published var segmentCount: Int = 0
    @Published var bufferDuration: TimeInterval = 0
    @Published var availableStorageGB: Double = 0
    @Published var isStorageLow = false
    @Published var interruptionReason: String?
    @Published var cameraError: CameraError?
    @Published var collisionDetected = false
    @Published var protectedCount: Int = 0
    @Published var elapsedTime: TimeInterval = 0
    @Published var showSaveDialog = false
    @Published var saveStatusMessage: String?

    // MARK: - Dependencies

    let cameraManager: CameraManager
    private let segmentRecorder: SegmentRecorder
    private let loopBuffer: LoopBufferManager
    private let collisionDetector: CollisionDetector
    private let fileProtection: FileProtectionManager
    private let storageManager: StorageManager
    private let autoRestart: AutoRestartService
    private let locationManager: SpeedTracker

    private var cancellables = Set<AnyCancellable>()
    private var recordingTimer: Timer?
    private var recordingStartTime: Date?
    private var delegateBridge: SegmentDelegateBridge?
    private var previousBrightness: CGFloat?
    private var isStarting = false

    // Collision handling
    private var isHandlingCollision = false
    private var isWaitingForCollisionSegment = false
    private var collisionGeneration = 0
    /// Give up waiting for the post-impact segment after this long, so one stuck
    /// collision cannot disable collision handling for the rest of the drive.
    private static let collisionSegmentTimeout: TimeInterval = 120

    // MARK: - Init

    init(config: DashcamConfig = DashcamConfig.load()) {
        self.config = config
        self.cameraManager = CameraManager()
        self.segmentRecorder = SegmentRecorder(cameraManager: cameraManager, config: config)
        self.loopBuffer = LoopBufferManager(config: config)
        self.collisionDetector = CollisionDetector(config: config)
        self.fileProtection = FileProtectionManager()
        self.storageManager = StorageManager()
        self.autoRestart = AutoRestartService()
        self.locationManager = SpeedTracker()

        setupBindings()
        setupCallbacks()
        cameraManager.refreshAvailability()
        storageManager.updateStorageInfo() // show real free space before the first recording
    }

    // MARK: - Public Actions

    func startRecording() {
        guard recordingState != .recording, !isStarting else { return }
        isStarting = true

        cameraManager.configureAndStart(with: config) { [weak self] isRunning in
            guard let self else { return }
            self.isStarting = false

            guard isRunning else {
                let message = self.cameraManager.error?.message
                    ?? NSLocalizedString("camera.error.unavailable", comment: "")
                self.recordingState = .error(message)
                return
            }

            self.segmentRecorder.startRecording()
            self.collisionDetector.startMonitoring()
            self.storageManager.startMonitoring()
            self.autoRestart.startObserving()
            self.autoRestart.setRecordingActive(true)
            self.locationManager.startTracking()

            self.recordingState = .recording
            if self.recordingStartTime == nil {
                self.recordingStartTime = Date()
            }
            self.startElapsedTimer()
            self.dimScreen()
        }
    }

    /// Stops recording without saving the buffer (the buffered footage stays until discarded).
    func stopRecording() {
        segmentRecorder.stopRecording()
        tearDownSession()
    }

    func toggleRecording() {
        if recordingState == .recording {
            showSaveDialog = true
        } else {
            startRecording()
        }
    }

    /// Manual save: stop recording, merge ALL buffer segments into one video, save to Photos.
    /// The buffer is only cleared once the clip is safely in Photos.
    func saveAndStopRecording() {
        segmentRecorder.stopRecording { [weak self] in
            guard let self else { return }
            self.tearDownSession()

            guard let request = self.loopBuffer.beginExport(trigger: .manual) else {
                self.saveStatusMessage = NSLocalizedString("status.noSegments", comment: "")
                self.clearSaveStatusLater()
                return
            }

            self.saveStatusMessage = NSLocalizedString("status.merging", comment: "")

            self.fileProtection.mergeSegmentsAndSaveToPhotos(
                segmentURLs: request.fileURLs,
                metadata: request.metadata,
                location: self.locationManager.lastLocation
            ) { [weak self] success, count in
                guard let self else { return }
                if success {
                    self.saveStatusMessage = String(
                        format: NSLocalizedString("status.savedCount %lld", comment: ""), count
                    )
                } else {
                    self.saveStatusMessage = NSLocalizedString("status.saveFailed", comment: "")
                }
                // Keep the footage if saving failed, so nothing is lost to a Photos permission problem.
                self.loopBuffer.endExport(request, clearBuffer: success)
                self.clearSaveStatusLater()
            }
        }
    }

    /// Discard all buffered segments and stop recording.
    func discardAndStopRecording() {
        // Wait for the last segment to be delivered before discarding, otherwise it
        // would arrive after the discard and land in the buffer.
        segmentRecorder.stopRecording { [weak self] in
            self?.loopBuffer.discardAllSegments()
        }
        tearDownSession()
    }

    /// Apply updated config (from settings). The loop length and collision sensitivity take
    /// effect immediately; resolution and codec are fixed.
    func applyConfig(_ newConfig: DashcamConfig) {
        config = newConfig
        config.save()
        loopBuffer.updateMaxSegments(newConfig.maxSegments)
        collisionDetector.updateThreshold(newConfig.collisionThreshold)
    }

    /// Re-checks camera availability and permission (for example after returning from Settings).
    func refreshCameraAvailability() {
        cameraManager.refreshAvailability()
    }

    // MARK: - Private

    private func tearDownSession() {
        collisionDetector.stopMonitoring()
        storageManager.stopMonitoring()
        autoRestart.setRecordingActive(false)
        autoRestart.stopObserving()
        locationManager.stopTracking()

        recordingState = .idle
        isHandlingCollision = false
        isWaitingForCollisionSegment = false
        stopElapsedTimer()
        restoreBrightness()
    }

    /// Called when the camera is interrupted or the app goes to the background:
    /// finish the current segment (with a background task so it can complete) and wait.
    private func pauseForInterruption() {
        guard recordingState == .recording else { return }
        recordingState = .paused

        let application = UIApplication.shared
        let task = BackgroundTask(application: application, name: "dashcam.finalize-segment")
        segmentRecorder.stopRecording {
            task.end()
        }
    }

    private func setupBindings() {
        collisionDetector.$currentGForce
            .receive(on: DispatchQueue.main)
            .assign(to: &$currentGForce)

        loopBuffer.$segments
            .map(\.count)
            .receive(on: DispatchQueue.main)
            .assign(to: &$segmentCount)

        loopBuffer.$totalBufferDuration
            .receive(on: DispatchQueue.main)
            .assign(to: &$bufferDuration)

        storageManager.$availableStorageGB
            .receive(on: DispatchQueue.main)
            .assign(to: &$availableStorageGB)

        storageManager.$isStorageLow
            .receive(on: DispatchQueue.main)
            .assign(to: &$isStorageLow)

        autoRestart.$interruptionReason
            .receive(on: DispatchQueue.main)
            .assign(to: &$interruptionReason)

        fileProtection.$protectedCount
            .receive(on: DispatchQueue.main)
            .assign(to: &$protectedCount)

        locationManager.$currentSpeed
            .receive(on: DispatchQueue.main)
            .assign(to: &$currentSpeed)

        locationManager.$isLocationDenied
            .receive(on: DispatchQueue.main)
            .assign(to: &$isLocationDenied)

        cameraManager.$error
            .receive(on: DispatchQueue.main)
            .assign(to: &$cameraError)
    }

    private func setupCallbacks() {
        let bridge = SegmentDelegateBridge { [weak self] segment in
            guard let self else { return }
            self.loopBuffer.addSegment(segment)
            // A finished segment proves the writer works again after an earlier failure.
            if case .error = self.recordingState, self.segmentRecorder.isRecording {
                self.recordingState = .recording
            }
        } onError: { [weak self] error in
            self?.recordingState = .error(error.localizedDescription)
        }
        self.delegateBridge = bridge
        segmentRecorder.delegate = bridge

        collisionDetector.onCollisionDetected = { [weak self] in
            self?.handleCollision()
        }

        storageManager.onSample = { [weak self] sample in
            self?.loopBuffer.enforceQuota(freeBytes: sample.freeBytes, bufferBytes: sample.bufferBytes)
        }

        autoRestart.onShouldRestart = { [weak self] in
            Task { @MainActor in
                guard self?.recordingState == .paused else { return }
                self?.startRecording()
            }
        }

        autoRestart.onShouldStop = { [weak self] in
            Task { @MainActor in
                self?.pauseForInterruption()
            }
        }
    }

    private func handleCollision() {
        guard recordingState == .recording, !isHandlingCollision else { return }
        isHandlingCollision = true
        isWaitingForCollisionSegment = true
        collisionDetected = true
        collisionGeneration += 1
        let generation = collisionGeneration

        // Delay 0.5s so the video includes a brief moment after impact
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.isHandlingCollision, self.collisionGeneration == generation else { return }

            self.segmentRecorder.onNextSegmentFinished = { [weak self] in
                self?.saveBufferAfterCollision(generation: generation)
            }
            self.segmentRecorder.finishCurrentSegmentAndContinue()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.collisionSegmentTimeout) { [weak self] in
            guard let self, self.collisionGeneration == generation, self.isWaitingForCollisionSegment else { return }
            Log.recording.error("timed out waiting for the post-collision segment")
            self.isWaitingForCollisionSegment = false
            self.isHandlingCollision = false
            self.segmentRecorder.onNextSegmentFinished = nil
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            self?.collisionDetected = false
        }
    }

    private func saveBufferAfterCollision(generation: Int) {
        guard collisionGeneration == generation else { return }
        isWaitingForCollisionSegment = false

        guard let request = loopBuffer.beginExport(trigger: .collision) else {
            saveStatusMessage = NSLocalizedString("status.collisionNoSegments", comment: "")
            isHandlingCollision = false
            clearSaveStatusLater()
            return
        }

        saveStatusMessage = NSLocalizedString("status.collisionSaving", comment: "")

        fileProtection.mergeSegmentsAndSaveToPhotos(
            segmentURLs: request.fileURLs,
            metadata: request.metadata,
            location: locationManager.lastLocation
        ) { [weak self] success, count in
            guard let self else { return }
            self.isHandlingCollision = false
            if success {
                self.saveStatusMessage = String(
                    format: NSLocalizedString("status.collisionSavedCount %lld", comment: ""), count
                )
            } else {
                self.saveStatusMessage = NSLocalizedString("status.collisionSaveFailed", comment: "")
            }
            // Recording continues after a collision, so the buffer is kept.
            self.loopBuffer.endExport(request, clearBuffer: false)
            self.clearSaveStatusLater()
        }
    }

    private func clearSaveStatusLater() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.saveStatusMessage = nil
        }
    }

    private func startElapsedTimer() {
        recordingTimer?.invalidate()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.recordingStartTime else { return }
                self.elapsedTime = Date().timeIntervalSince(start)
            }
        }
    }

    private func stopElapsedTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        elapsedTime = 0
        recordingStartTime = nil
    }

    private func dimScreen() {
        // Remember the user's brightness only once; resuming after a pause must not
        // overwrite it with the already-dimmed value.
        if previousBrightness == nil {
            previousBrightness = UIScreen.main.brightness
        }
        UIScreen.main.brightness = 0.1
    }

    private func restoreBrightness() {
        if let previous = previousBrightness {
            UIScreen.main.brightness = previous
            previousBrightness = nil
        }
    }
}

// MARK: - Background task

/// Keeps the app alive for the few seconds a segment needs to be finalized after the
/// app moves to the background.
private final class BackgroundTask {
    private var identifier = UIBackgroundTaskIdentifier.invalid
    private let application: UIApplication

    @MainActor
    init(application: UIApplication, name: String) {
        self.application = application
        identifier = application.beginBackgroundTask(withName: name) { [weak self] in
            Task { @MainActor in self?.end() }
        }
    }

    @MainActor
    func end() {
        guard identifier != .invalid else { return }
        application.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

// MARK: - Bridge for delegate

private final class SegmentDelegateBridge: SegmentRecorderDelegate {
    let onFinish: (Segment) -> Void
    let onError: (Error) -> Void

    init(onFinish: @escaping (Segment) -> Void, onError: @escaping (Error) -> Void) {
        self.onFinish = onFinish
        self.onError = onError
    }

    func segmentRecorder(_ recorder: SegmentRecorder, didFinishSegment segment: Segment) {
        onFinish(segment)
    }

    func segmentRecorder(_ recorder: SegmentRecorder, didFailWithError error: Error) {
        onError(error)
    }
}
