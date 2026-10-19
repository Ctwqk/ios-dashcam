import AVFoundation
import UIKit
import Combine

/// Tracks app, capture-session and runtime interruptions independently. Recording may
/// resume only after every interruption has ended and the app is active.
final class AutoRestartService: ObservableObject {
    @Published private(set) var interruptionReason: String?
    @Published private(set) var isRecovering = false

    var onShouldRestart: (() -> Void)?
    var onShouldStop: (() -> Void)?

    private enum Cause: CaseIterable { case background, capture, runtime }
    private var reasons: [Cause: String] = [:]
    private var wasRecordingBeforeInterruption = false
    private var recoveryGeneration = 0
    private var runtimeGeneration = 0
    private var cancellables = Set<AnyCancellable>()
    private let session: AVCaptureSession
    private let notificationCenter: NotificationCenter
    private let applicationIsActive: () -> Bool
    private let recoveryDelay: TimeInterval

    init(
        session: AVCaptureSession,
        notificationCenter: NotificationCenter = .default,
        recoveryDelay: TimeInterval = 0.5,
        applicationIsActive: @escaping () -> Bool = { UIApplication.shared.applicationState == .active }
    ) {
        self.session = session
        self.notificationCenter = notificationCenter
        self.recoveryDelay = recoveryDelay
        self.applicationIsActive = applicationIsActive
    }

    /// Safe to call repeatedly without stacking subscriptions.
    func startObserving() {
        cancellables.removeAll()
        cancelRecovery()

        notificationCenter.publisher(for: .AVCaptureSessionWasInterrupted, object: session)
            .compactMap { $0.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int }
            .compactMap { AVCaptureSession.InterruptionReason(rawValue: $0) }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] reason in self?.handleInterruption(reason) }
            .store(in: &cancellables)

        notificationCenter.publisher(for: .AVCaptureSessionInterruptionEnded, object: session)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.end(.capture) }
            .store(in: &cancellables)

        // Permission prompts resign active but do not background the app.
        notificationCenter.publisher(for: UIApplication.didEnterBackgroundNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.begin(.background, message: "App moved to background") }
            .store(in: &cancellables)

        notificationCenter.publisher(for: UIApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.end(.background) }
            .store(in: &cancellables)

        notificationCenter.publisher(for: .AVCaptureSessionRuntimeError, object: session)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self,
                      let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError else { return }
                self.begin(.runtime, message: "Runtime error: \(error.localizedDescription)")
                self.runtimeGeneration += 1
                let generation = self.runtimeGeneration
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    guard let self, self.runtimeGeneration == generation else { return }
                    self.end(.runtime)
                }
            }
            .store(in: &cancellables)
    }

    func stopObserving() {
        cancellables.removeAll()
        wasRecordingBeforeInterruption = false
        runtimeGeneration += 1
        cancelRecovery()
        reasons.removeAll()
        interruptionReason = nil
    }

    func setRecordingActive(_ active: Bool) {
        wasRecordingBeforeInterruption = active
        if !active { cancelRecovery() }
    }

    private func handleInterruption(_ reason: AVCaptureSession.InterruptionReason) {
        let message: String
        switch reason {
        case .videoDeviceNotAvailableInBackground: message = "App in background"
        case .audioDeviceInUseByAnotherClient: message = "Audio device in use"
        case .videoDeviceNotAvailableWithMultipleForegroundApps: message = "Multi-app conflict"
        case .videoDeviceNotAvailableDueToSystemPressure: message = "System thermal pressure"
        default: message = "Recording interrupted"
        }
        begin(.capture, message: message)
    }

    private func begin(_ cause: Cause, message: String) {
        cancelRecovery()
        reasons[cause] = message
        publishReason()
        onShouldStop?()
    }

    private func end(_ cause: Cause) {
        reasons[cause] = nil
        publishReason()
        guard reasons.isEmpty, wasRecordingBeforeInterruption, applicationIsActive(), !isRecovering else { return }
        isRecovering = true
        let generation = recoveryGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + recoveryDelay) { [weak self] in
            guard let self, self.recoveryGeneration == generation else { return }
            self.isRecovering = false
            guard self.reasons.isEmpty, self.wasRecordingBeforeInterruption, self.applicationIsActive() else { return }
            self.onShouldRestart?()
        }
    }

    private func cancelRecovery() {
        recoveryGeneration += 1
        isRecovering = false
    }

    private func publishReason() {
        interruptionReason = Cause.allCases.compactMap { reasons[$0] }.first
    }
}
