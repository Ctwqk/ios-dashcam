import XCTest
@testable import DashCamCore

final class OrderedCompletionQueueTests: XCTestCase {
    func testOutOfOrderWritersAreDeliveredInRecordingOrder() {
        let queue = OrderedCompletionQueue<Int>()
        var delivered: [Int] = []
        let first = queue.enqueue { delivered.append($0) }
        let second = queue.enqueue { delivered.append($0) }
        let third = queue.enqueue { delivered.append($0) }

        queue.complete(second, with: 2)
        queue.complete(third, with: 3)
        XCTAssertTrue(delivered.isEmpty)
        queue.complete(first, with: 1)
        XCTAssertEqual(delivered, [1, 2, 3])
    }

    func testStopWaitsForRotatedWriterAsWellAsActiveWriter() {
        let queue = OrderedCompletionQueue<String>()
        var events: [String] = []
        let rotating = queue.enqueue { events.append($0) }
        let active = queue.enqueue { events.append($0) }
        queue.barrier { events.append("stop") }
        queue.barrier { events.append("second stop") }

        queue.complete(active, with: "active")
        XCTAssertTrue(events.isEmpty, "stop must not snapshot or discard while a rotation is pending")
        queue.complete(rotating, with: "rotating")
        XCTAssertEqual(events, ["rotating", "active", "stop", "second stop"])
    }

    func testCollisionCallbackBelongsToRequestedSegment() {
        let queue = OrderedCompletionQueue<Int>()
        var collisionSaved = false
        let previousRotation = queue.enqueue { _ in }
        let impact = queue.enqueue { _ in collisionSaved = true }
        queue.complete(previousRotation, with: 1)
        XCTAssertFalse(collisionSaved)
        queue.complete(impact, with: 2)
        XCTAssertTrue(collisionSaved)
    }

    func testBarrierDoesNotWaitForRecordingStartedLater() {
        let queue = OrderedCompletionQueue<Int>()
        var stopped = false
        let previous = queue.enqueue { _ in }
        queue.barrier { stopped = true }
        let nextRecording = queue.enqueue { _ in }
        queue.complete(previous, with: 1)
        XCTAssertTrue(stopped)
        queue.complete(nextRecording, with: 2)
    }

    func testFailureIsDeliveredAndDoesNotBlockStop() {
        enum Failure: Error { case diskFull }
        let queue = OrderedCompletionQueue<Result<Int, Error>>()
        var failed = false
        var stopped = false
        let ticket = queue.enqueue {
            if case .failure = $0 { failed = true }
        }
        queue.barrier { stopped = true }
        queue.complete(ticket, with: .failure(Failure.diskFull))
        XCTAssertTrue(failed)
        XCTAssertTrue(stopped)
    }

    func testDuplicateCompletionDoesNotDeliverTwice() {
        let queue = OrderedCompletionQueue<Int>()
        var delivered: [Int] = []
        let ticket = queue.enqueue { delivered.append($0) }
        queue.complete(ticket, with: 1)
        queue.complete(ticket, with: 2)
        queue.complete(UUID(), with: 3)
        XCTAssertEqual(delivered, [1])
    }

    func testIdleBarrierRunsImmediately() {
        let queue = OrderedCompletionQueue<Int>()
        var stopped = false
        queue.barrier { stopped = true }
        XCTAssertTrue(stopped)
    }
}
