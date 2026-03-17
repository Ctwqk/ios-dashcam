import AVFoundation
import UIKit
import Combine

final class AutoRestartService: ObservableObject {
    @Published private(set) var interruptionReason: String?
    @Published private(set) var isRecovering = false

    var onShouldRestart: (() -> Void)?
    var onShouldStop: (() -> Void)?

    /// Tracks whether recording was active before an interruption occurred.
    private var wasRecordingBeforeInterruption = false
    private var cancellables = Set<AnyCancellable>()

    func startObserving() {
        // AVCaptureSession interruption
        NotificationCenter.default.publisher(for: .AVCaptureSessionWasInterrupted)
            .compactMap { $0.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int }
            .compactMap { AVCaptureSession.InterruptionReason(rawValue: $0) }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] reason in
                self?.handleInterruption(reason)
            }
            .store(in: &cancellables)

        // AVCaptureSession interruption ended
        NotificationCenter.default.publisher(for: .AVCaptureSessionInterruptionEnded)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleInterruptionEnded()
            }
            .store(in: &cancellables)

        // App lifecycle
        NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.interruptionReason = "App moved to background"
                self?.onShouldStop?()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleInterruptionEnded()
            }
            .store(in: &cancellables)

        // Runtime errors
        NotificationCenter.default.publisher(for: .AVCaptureSessionRuntimeError)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                if let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError {
                    self?.interruptionReason = "Runtime error: \(error.localizedDescription)"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        self?.handleInterruptionEnded()
                    }
                }
            }
            .store(in: &cancellables)
    }

    func stopObserving() {
        cancellables.removeAll()
    }

    func setRecordingActive(_ active: Bool) {
        if active {
            wasRecordingBeforeInterruption = true
        }
    }

    // MARK: - Private

    private func handleInterruption(_ reason: AVCaptureSession.InterruptionReason) {
        switch reason {
        case .videoDeviceNotAvailableInBackground:
            interruptionReason = "App in background"
        case .audioDeviceInUseByAnotherClient:
            interruptionReason = "Audio device in use"
        case .videoDeviceNotAvailableWithMultipleForegroundApps:
            interruptionReason = "Multi-app conflict"
        case .videoDeviceNotAvailableDueToSystemPressure:
            interruptionReason = "System thermal pressure"
        default:
            interruptionReason = "Recording interrupted"
        }
        onShouldStop?()
    }

    private func handleInterruptionEnded() {
        guard interruptionReason != nil else { return }
        isRecovering = true
        interruptionReason = nil

        guard wasRecordingBeforeInterruption else {
            isRecovering = false
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.isRecovering = false
            self?.onShouldRestart?()
        }
    }

    deinit {
        stopObserving()
    }
}
