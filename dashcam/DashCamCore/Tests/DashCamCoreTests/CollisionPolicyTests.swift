import XCTest
@testable import DashCamCore

final class CollisionPolicyTests: XCTestCase {
    func testMagnitudeOfRestingDeviceIsAboutOneG() {
        XCTAssertEqual(CollisionDetectionPolicy.magnitude(x: 0, y: 0, z: -1), 1, accuracy: 1e-9)
    }

    func testMagnitudeCombinesAllAxes() {
        XCTAssertEqual(CollisionDetectionPolicy.magnitude(x: 3, y: 4, z: 12), 13, accuracy: 1e-9)
    }

    func testBelowThresholdDoesNotTrigger() {
        var policy = CollisionDetectionPolicy(threshold: 3.0)
        XCTAssertFalse(policy.evaluate(gForce: 1.0, timestamp: 0))
        XCTAssertFalse(policy.evaluate(gForce: 2.99, timestamp: 1))
        XCTAssertNil(policy.lastTriggerTimestamp)
    }

    func testReachingTheThresholdTriggers() {
        var policy = CollisionDetectionPolicy(threshold: 3.0)
        XCTAssertTrue(policy.evaluate(gForce: 3.0, timestamp: 5))
        XCTAssertEqual(policy.lastTriggerTimestamp, 5)
    }

    func testOneImpactIsReportedOnceAtFiftyHertz() {
        var policy = CollisionDetectionPolicy(threshold: 3.0, debounceInterval: 10)
        var triggers = 0
        // A 200 ms impact sampled at 50 Hz is 10 consecutive over-threshold samples.
        for sample in 0..<10 where policy.evaluate(gForce: 4.2, timestamp: 100 + Double(sample) * 0.02) {
            triggers += 1
        }
        XCTAssertEqual(triggers, 1)
    }

    func testSecondImpactAfterTheDebounceWindowTriggersAgain() {
        var policy = CollisionDetectionPolicy(threshold: 3.0, debounceInterval: 10)
        XCTAssertTrue(policy.evaluate(gForce: 4, timestamp: 100))
        XCTAssertFalse(policy.evaluate(gForce: 4, timestamp: 109.9))
        XCTAssertTrue(policy.evaluate(gForce: 4, timestamp: 110))
    }

    func testSuppressedSamplesDoNotExtendTheDebounceWindow() {
        var policy = CollisionDetectionPolicy(threshold: 3.0, debounceInterval: 10)
        XCTAssertTrue(policy.evaluate(gForce: 4, timestamp: 0))
        XCTAssertFalse(policy.evaluate(gForce: 4, timestamp: 9))
        XCTAssertTrue(policy.evaluate(gForce: 4, timestamp: 10))
    }

    func testLoweringTheThresholdTakesEffectImmediately() {
        var policy = CollisionDetectionPolicy(threshold: 4.0)
        XCTAssertFalse(policy.evaluate(gForce: 2.6, timestamp: 0))
        policy.threshold = 2.5
        XCTAssertTrue(policy.evaluate(gForce: 2.6, timestamp: 1))
    }

    func testNonFiniteSamplesAreIgnored() {
        var policy = CollisionDetectionPolicy(threshold: 3.0)
        XCTAssertFalse(policy.evaluate(gForce: .nan, timestamp: 0))
        XCTAssertFalse(policy.evaluate(gForce: .infinity, timestamp: 1))
        XCTAssertFalse(policy.evaluate(gForce: 4, timestamp: .nan))
    }

    func testAClockThatGoesBackwardsStartsANewEpoch() {
        var policy = CollisionDetectionPolicy(threshold: 3.0, debounceInterval: 10)
        XCTAssertTrue(policy.evaluate(gForce: 4, timestamp: 5_000))
        XCTAssertTrue(policy.evaluate(gForce: 4, timestamp: 3))
    }

    func testResetClearsTheDebounce() {
        var policy = CollisionDetectionPolicy(threshold: 3.0)
        XCTAssertTrue(policy.evaluate(gForce: 4, timestamp: 1))
        policy.reset()
        XCTAssertTrue(policy.evaluate(gForce: 4, timestamp: 2))
    }
}
