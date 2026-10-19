import AVFoundation
import UIKit
import XCTest

@MainActor
final class InterruptionTests: XCTestCase {
    func testForegroundWaitsForCaptureInterruptionToEnd() async {
        let center = NotificationCenter()
        let session = AVCaptureSession()
        var active = false
        let service = AutoRestartService(
            session: session, notificationCenter: center, recoveryDelay: 0.01, applicationIsActive: { active }
        )
        service.startObserving()
        service.setRecordingActive(true)
        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        interrupt(session, center: center)
        await flushNotifications()

        active = true
        let premature = expectation(description: "must not resume during camera interruption")
        premature.isInverted = true
        service.onShouldRestart = { premature.fulfill() }
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        await fulfillment(of: [premature], timeout: 0.1)
        XCTAssertNotNil(service.interruptionReason)

        let resumed = expectation(description: "all interruptions ended")
        service.onShouldRestart = { resumed.fulfill() }
        center.post(name: .AVCaptureSessionInterruptionEnded, object: session)
        await fulfillment(of: [resumed], timeout: 1)
        XCTAssertNil(service.interruptionReason)
    }

    func testCaptureRecoveryWaitsForForeground() async {
        let center = NotificationCenter()
        let session = AVCaptureSession()
        var active = false
        let service = AutoRestartService(
            session: session, notificationCenter: center, recoveryDelay: 0.01, applicationIsActive: { active }
        )
        service.startObserving()
        service.setRecordingActive(true)
        interrupt(session, center: center)
        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        center.post(name: .AVCaptureSessionInterruptionEnded, object: session)
        await flushNotifications()
        XCTAssertNotNil(service.interruptionReason)
        XCTAssertFalse(service.isRecovering)

        active = true
        let resumed = expectation(description: "resume when foregrounded")
        service.onShouldRestart = { resumed.fulfill() }
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        await fulfillment(of: [resumed], timeout: 1)
    }

    func testNewInterruptionCancelsScheduledRestart() async {
        let center = NotificationCenter()
        let session = AVCaptureSession()
        let service = AutoRestartService(
            session: session, notificationCenter: center, recoveryDelay: 0.05, applicationIsActive: { true }
        )
        service.startObserving()
        service.setRecordingActive(true)
        interrupt(session, center: center)
        center.post(name: .AVCaptureSessionInterruptionEnded, object: session)
        await flushNotifications()
        XCTAssertTrue(service.isRecovering)
        let premature = expectation(description: "stale restart cancelled")
        premature.isInverted = true
        service.onShouldRestart = { premature.fulfill() }
        interrupt(session, center: center)
        await fulfillment(of: [premature], timeout: 0.15)
        XCTAssertFalse(service.isRecovering)
    }

    func testManualStopCancelsScheduledRestart() async {
        let center = NotificationCenter()
        let session = AVCaptureSession()
        let service = AutoRestartService(
            session: session, notificationCenter: center, recoveryDelay: 0.05, applicationIsActive: { true }
        )
        service.startObserving()
        service.setRecordingActive(true)
        interrupt(session, center: center)
        center.post(name: .AVCaptureSessionInterruptionEnded, object: session)
        await flushNotifications()
        let restarted = expectation(description: "manual stop wins")
        restarted.isInverted = true
        service.onShouldRestart = { restarted.fulfill() }
        service.stopObserving()
        await fulfillment(of: [restarted], timeout: 0.15)
        XCTAssertFalse(service.isRecovering)
    }

    func testObserversDoNotStackAndIgnoreOtherSessions() async {
        let center = NotificationCenter()
        let session = AVCaptureSession()
        let service = AutoRestartService(session: session, notificationCenter: center)
        var stops = 0
        service.onShouldStop = { stops += 1 }
        service.startObserving()
        service.startObserving()
        interrupt(AVCaptureSession(), center: center)
        await flushNotifications()
        XCTAssertEqual(stops, 0)
        interrupt(session, center: center)
        await flushNotifications()
        XCTAssertEqual(stops, 1)
        service.stopObserving()
    }

    func testRuntimeErrorStopsRecordingBeforeRetry() async {
        let center = NotificationCenter()
        let session = AVCaptureSession()
        let service = AutoRestartService(session: session, notificationCenter: center)
        let stopped = expectation(description: "runtime error pauses writer")
        service.onShouldStop = { stopped.fulfill() }
        service.startObserving()
        service.setRecordingActive(true)
        let error = NSError(domain: AVFoundationErrorDomain, code: AVError.mediaServicesWereReset.rawValue)
        center.post(name: .AVCaptureSessionRuntimeError, object: session, userInfo: [AVCaptureSessionErrorKey: error])
        await fulfillment(of: [stopped], timeout: 1)
        service.stopObserving()
    }

    private func interrupt(_ session: AVCaptureSession, center: NotificationCenter) {
        center.post(name: .AVCaptureSessionWasInterrupted, object: session, userInfo: [
            AVCaptureSessionInterruptionReasonKey: AVCaptureSession.InterruptionReason.audioDeviceInUseByAnotherClient.rawValue
        ])
    }

    private func flushNotifications() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
