import AVFoundation
import UIKit
import Combine

/// Watches for anything that stops the camera (phone call, another app using the mic,
/// thermal pressure, the app going to the background) and asks the view model to stop,
/// then to resume once the interruption is over.
final class AutoRestartService: ObservableObject {
    @Published private(set) var interruptionReason: String?
    @Published private(set) var isRecovering = false

    var onShouldRestart: (() -> Void)?
    var onShouldStop: (() -> Void)?

    /// Tracks whether recording was active before an interruption occurred.
    private var wasRecordingBeforeInterruption = false
    private var cancellables = Set<AnyCancellable>()

    /// Safe to call repeatedly: earlier subscriptions are dropped first, otherwise every
    /// restart would stack another copy of each observer.
    func startObserving() {
        cancellables.removeAll()

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

        // App lifecycle. Only a real trip to the background stops recording: the app also
        // resigns active for permission prompts, Control Center and notification banners,
        // none of which interrupt the camera.
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
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
        interruptionReason = nil
    }

    func setRecordingActive(_ active: Bool) {
        wasRecordingBeforeInterruption = active
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
        cancellables.removeAll()
    }
}
