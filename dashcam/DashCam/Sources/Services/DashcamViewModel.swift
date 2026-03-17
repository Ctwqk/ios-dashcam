import SwiftUI
import UIKit
import Combine
import CoreLocation

@MainActor
final class DashcamViewModel: ObservableObject {
    // MARK: - Published State

    @Published var recordingState: RecordingState = .idle
    @Published var currentSpeed: Double = 0 // km/h
    @Published var currentGForce: Double = 0
    @Published var segmentCount: Int = 0
    @Published var bufferDuration: TimeInterval = 0
    @Published var availableStorageGB: Double = 0
    @Published var isStorageLow = false
    @Published var interruptionReason: String?
    @Published var collisionDetected = false
    @Published var protectedCount: Int = 0
    @Published var elapsedTime: TimeInterval = 0
    @Published var showSaveDialog = false
    @Published var saveStatusMessage: String?

    // MARK: - Dependencies

    var config: DashcamConfig
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
    private var isHandlingCollision = false

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
    }

    // MARK: - Public Actions

    func startRecording() {
        guard recordingState != .recording else { return }

        cameraManager.configureAndStart(with: config) { [weak self] in
            guard let self else { return }
            self.segmentRecorder.startRecording()
            self.collisionDetector.startMonitoring()
            self.storageManager.startMonitoring()
            self.autoRestart.startObserving()
            self.autoRestart.setRecordingActive(true)
            self.locationManager.startTracking()

            self.recordingState = .recording
            self.recordingStartTime = Date()
            self.startElapsedTimer()
            self.dimScreen()
        }
    }

    func stopRecording() {
        segmentRecorder.stopRecording()
        collisionDetector.stopMonitoring()
        storageManager.stopMonitoring()
        autoRestart.setRecordingActive(false)
        autoRestart.stopObserving()
        locationManager.stopTracking()

        recordingState = .idle
        stopElapsedTimer()
        restoreBrightness()
    }

    func toggleRecording() {
        if recordingState == .recording {
            showSaveDialog = true
        } else {
            startRecording()
        }
    }

    /// Manual save: stop recording, merge ALL buffer segments into one video, save to Photos, clear buffer.
    func saveAndStopRecording() {
        segmentRecorder.stopRecording { [weak self] in
            guard let self else { return }

            self.collisionDetector.stopMonitoring()
            self.storageManager.stopMonitoring()
            self.autoRestart.setRecordingActive(false)
            self.autoRestart.stopObserving()
            self.locationManager.stopTracking()
            self.recordingState = .idle
            self.stopElapsedTimer()
            self.restoreBrightness()

            let segmentURLs = self.loopBuffer.allSegmentFileURLs()

            guard !segmentURLs.isEmpty else {
                self.saveStatusMessage = NSLocalizedString("status.noSegments", comment: "")
                self.clearSaveStatusLater()
                return
            }

            self.saveStatusMessage = NSLocalizedString("status.merging", comment: "")

            self.fileProtection.mergeSegmentsAndSaveToPhotos(
                segmentURLs: segmentURLs,
                label: "manual"
            ) { [weak self] success, count in
                guard let self else { return }
                if success {
                    self.saveStatusMessage = String(format: NSLocalizedString("status.savedCount %lld", comment: ""), count)
                } else {
                    self.saveStatusMessage = NSLocalizedString("status.saveFailed", comment: "")
                }
                self.loopBuffer.clearBuffer()
                self.clearSaveStatusLater()
            }
        }
    }

    /// Discard all buffered segments and stop recording.
    func discardAndStopRecording() {
        stopRecording()
        loopBuffer.discardAllSegments()
    }

    /// Apply updated config (from settings). Takes effect on next recording start.
    func applyConfig(_ newConfig: DashcamConfig) {
        config = newConfig
        config.save()
        loopBuffer.updateMaxSegments(newConfig.maxSegments)
    }

    // MARK: - Private

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
    }

    private func setupCallbacks() {
        let bridge = SegmentDelegateBridge { [weak self] segment in
            self?.loopBuffer.addSegment(segment)
        } onError: { [weak self] error in
            self?.recordingState = .error(error.localizedDescription)
        }
        self.delegateBridge = bridge
        segmentRecorder.delegate = bridge

        collisionDetector.onCollisionDetected = { [weak self] in
            self?.handleCollision()
        }

        autoRestart.onShouldRestart = { [weak self] in
            Task { @MainActor in
                self?.startRecording()
            }
        }

        autoRestart.onShouldStop = { [weak self] in
            Task { @MainActor in
                self?.segmentRecorder.stopRecording()
                self?.recordingState = .paused
            }
        }
    }

    private func handleCollision() {
        guard !isHandlingCollision else { return }
        isHandlingCollision = true
        collisionDetected = true

        // Delay 0.5s so the video includes a brief moment after impact
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.isHandlingCollision else { return }

            self.segmentRecorder.onNextSegmentFinished = { [weak self] in
                guard let self else { return }

                let segmentURLs = self.loopBuffer.allSegmentFileURLs()

                guard !segmentURLs.isEmpty else {
                    self.saveStatusMessage = NSLocalizedString("status.collisionNoSegments", comment: "")
                    self.isHandlingCollision = false
                    self.clearSaveStatusLater()
                    return
                }

                self.saveStatusMessage = NSLocalizedString("status.collisionSaving", comment: "")

                self.fileProtection.mergeSegmentsAndSaveToPhotos(
                    segmentURLs: segmentURLs,
                    label: "collision"
                ) { [weak self] success, count in
                    guard let self else { return }
                    self.isHandlingCollision = false
                    if success {
                        self.saveStatusMessage = String(format: NSLocalizedString("status.collisionSavedCount %lld", comment: ""), count)
                    } else {
                        self.saveStatusMessage = NSLocalizedString("status.collisionSaveFailed", comment: "")
                    }
                    self.clearSaveStatusLater()
                }
            }
            self.segmentRecorder.finishCurrentSegmentAndContinue()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            self?.collisionDetected = false
        }
    }

    private func clearSaveStatusLater() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.saveStatusMessage = nil
        }
    }

    private func startElapsedTimer() {
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
        previousBrightness = UIScreen.main.brightness
        UIScreen.main.brightness = 0.1
    }

    private func restoreBrightness() {
        if let previous = previousBrightness {
            UIScreen.main.brightness = previous
            previousBrightness = nil
        }
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
