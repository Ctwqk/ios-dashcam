import XCTest
@testable import DashCamCore

final class LoopBufferTests: XCTestCase {
    func testAppendBelowLimitEvictsNothing() {
        var buffer = LoopBuffer(maxSegments: 3)
        for segment in makeSegments(3) {
            XCTAssertTrue(buffer.append(segment).isEmpty)
        }
        XCTAssertEqual(buffer.segments.count, 3)
    }

    func testOverflowEvictsOldestFirst() {
        var buffer = LoopBuffer(maxSegments: 3)
        let segments = makeSegments(5)
        var evicted: [Segment] = []
        segments.forEach { evicted += buffer.append($0) }

        XCTAssertEqual(evicted.map(\.id), [segments[0].id, segments[1].id])
        XCTAssertEqual(buffer.segments.map(\.id), [segments[2].id, segments[3].id, segments[4].id])
    }

    func testBufferNeverExceedsMaxSegments() {
        var buffer = LoopBuffer(maxSegments: 4)
        for segment in makeSegments(50) {
            buffer.append(segment)
            XCTAssertLessThanOrEqual(buffer.segments.count, 4)
        }
        XCTAssertEqual(buffer.segments.count, 4)
    }

    func testShrinkingTheLoopEvictsTheOldest() {
        var buffer = LoopBuffer(maxSegments: 5)
        let segments = makeSegments(5)
        segments.forEach { buffer.append($0) }

        let evicted = buffer.setMaxSegments(2)
        XCTAssertEqual(evicted.map(\.id), segments[0..<3].map(\.id))
        XCTAssertEqual(buffer.segments.map(\.id), segments[3...].map(\.id))
    }

    func testGrowingTheLoopEvictsNothing() {
        var buffer = LoopBuffer(maxSegments: 2)
        makeSegments(2).forEach { buffer.append($0) }
        XCTAssertTrue(buffer.setMaxSegments(10).isEmpty)
        XCTAssertEqual(buffer.segments.count, 2)
    }

    func testMaxSegmentsIsClampedToAtLeastOne() {
        var buffer = LoopBuffer(maxSegments: 0)
        XCTAssertEqual(buffer.maxSegments, 1)
        buffer.setMaxSegments(-4)
        XCTAssertEqual(buffer.maxSegments, 1)
    }

    func testTotalDurationIgnoresUnfinishedSegments() {
        var buffer = LoopBuffer(maxSegments: 10)
        buffer.append(makeSegment(startingAt: 0, duration: 60))
        buffer.append(makeSegment(startingAt: 60, duration: 45))
        buffer.append(makeSegment(startingAt: 120, duration: nil))
        XCTAssertEqual(buffer.totalDuration, 105, accuracy: 0.001)
    }

    func testRemoveAllReturnsEverythingAndEmptiesTheBuffer() {
        var buffer = LoopBuffer(maxSegments: 5)
        let segments = makeSegments(3)
        segments.forEach { buffer.append($0) }

        XCTAssertEqual(buffer.removeAll().map(\.id), segments.map(\.id))
        XCTAssertTrue(buffer.segments.isEmpty)
        XCTAssertEqual(buffer.totalDuration, 0)
    }

    // MARK: - Export hold

    func testHeldSegmentIsEvictedFromTheLoopButItsDeletionIsDeferred() {
        var buffer = LoopBuffer(maxSegments: 2)
        let segments = makeSegments(2)
        segments.forEach { buffer.append($0) }
        buffer.hold(segments.map(\.id))

        let next = makeSegment(startingAt: 120)
        let deletableNow = buffer.append(next)

        XCTAssertTrue(deletableNow.isEmpty, "a held segment's file must not be deleted during export")
        XCTAssertEqual(buffer.segments.map(\.id), [segments[1].id, next.id])

        XCTAssertEqual(buffer.releaseHold().map(\.id), [segments[0].id])
        XCTAssertTrue(buffer.releaseHold().isEmpty, "deferred deletions are reported only once")
    }

    func testUnheldSegmentsAreStillDeletedWhileOthersAreHeld() {
        var buffer = LoopBuffer(maxSegments: 3)
        let segments = makeSegments(3)
        segments.forEach { buffer.append($0) }
        buffer.hold([segments[0].id])

        let deletable = buffer.setMaxSegments(1)

        XCTAssertEqual(deletable.map(\.id), [segments[1].id])
        XCTAssertEqual(buffer.releaseHold().map(\.id), [segments[0].id])
    }

    func testRemoveAllDefersHeldSegments() {
        var buffer = LoopBuffer(maxSegments: 3)
        let segments = makeSegments(3)
        segments.forEach { buffer.append($0) }
        buffer.hold([segments[1].id])

        XCTAssertEqual(Set(buffer.removeAll().map(\.id)), [segments[0].id, segments[2].id])
        XCTAssertEqual(buffer.releaseHold().map(\.id), [segments[1].id])
    }

    func testReleasingWithoutAHoldIsANoOp() {
        var buffer = LoopBuffer(maxSegments: 2)
        XCTAssertTrue(buffer.releaseHold().isEmpty)
    }

    // MARK: - Policy

    func testMaxSegmentsCoversTheBufferDuration() {
        XCTAssertEqual(LoopBufferPolicy.maxSegments(bufferDuration: 900, segmentDuration: 60), 15)
        XCTAssertEqual(LoopBufferPolicy.maxSegments(bufferDuration: 21_600, segmentDuration: 60), 360)
    }

    func testMaxSegmentsRoundsPartialSegmentsUp() {
        XCTAssertEqual(LoopBufferPolicy.maxSegments(bufferDuration: 900, segmentDuration: 40), 23)
    }

    func testMaxSegmentsHandlesDegenerateInput() {
        XCTAssertEqual(LoopBufferPolicy.maxSegments(bufferDuration: 0, segmentDuration: 60), 1)
        XCTAssertEqual(LoopBufferPolicy.maxSegments(bufferDuration: 900, segmentDuration: 0), 1)
        XCTAssertEqual(LoopBufferPolicy.maxSegments(bufferDuration: -5, segmentDuration: 60), 1)
    }
}
