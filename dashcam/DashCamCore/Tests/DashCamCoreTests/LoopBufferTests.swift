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

        XCTAssertEqual(buffer.release(segments.map(\.id)).map(\.id), [segments[0].id])
        XCTAssertTrue(buffer.release(segments.map(\.id)).isEmpty, "deferred deletions are reported only once")
    }

    func testUnheldSegmentsAreStillDeletedWhileOthersAreHeld() {
        var buffer = LoopBuffer(maxSegments: 3)
        let segments = makeSegments(3)
        segments.forEach { buffer.append($0) }
        buffer.hold([segments[0].id])

        let deletable = buffer.setMaxSegments(1)

        XCTAssertEqual(deletable.map(\.id), [segments[1].id])
        XCTAssertEqual(buffer.release([segments[0].id]).map(\.id), [segments[0].id])
    }

    func testRemoveAllDefersHeldSegments() {
        var buffer = LoopBuffer(maxSegments: 3)
        let segments = makeSegments(3)
        segments.forEach { buffer.append($0) }
        buffer.hold([segments[1].id])

        XCTAssertEqual(Set(buffer.removeAll().map(\.id)), [segments[0].id, segments[2].id])
        XCTAssertEqual(buffer.release([segments[1].id]).map(\.id), [segments[1].id])
    }

    func testOverlappingExportsKeepTheFileUntilTheLastOneFinishes() {
        var buffer = LoopBuffer(maxSegments: 1)
        let segments = makeSegments(1)
        buffer.append(segments[0])
        buffer.hold([segments[0].id])   // e.g. collision export
        buffer.hold([segments[0].id])   // e.g. manual save while the first is running

        XCTAssertTrue(buffer.append(makeSegment(startingAt: 60)).isEmpty)
        XCTAssertTrue(buffer.release([segments[0].id]).isEmpty, "one export is still using the file")
        XCTAssertEqual(buffer.release([segments[0].id]).map(\.id), [segments[0].id])
    }

    func testReleasingWithoutAHoldIsANoOp() {
        var buffer = LoopBuffer(maxSegments: 2)
        XCTAssertTrue(buffer.release([UUID()]).isEmpty)
    }

    func testSuccessfulSaveRemovesOnlyItsSnapshot() {
        var buffer = LoopBuffer(maxSegments: 5)
        let segments = makeSegments(3)
        buffer.append(segments[0])
        buffer.append(segments[1])
        let snapshot = buffer.segments.map(\.id)
        buffer.hold(snapshot)
        buffer.append(segments[2]) // Recording resumed while Photos was saving.

        XCTAssertTrue(buffer.remove(snapshot).isEmpty)
        XCTAssertEqual(buffer.segments.map(\.id), [segments[2].id])
        XCTAssertEqual(buffer.release(snapshot).map(\.id), snapshot)
        XCTAssertTrue(buffer.remove(snapshot).isEmpty)
    }

    func testSavedSnapshotStillHonorsAnOverlappingExport() {
        var buffer = LoopBuffer(maxSegments: 2)
        let segments = makeSegments(3)
        buffer.append(segments[0])
        buffer.append(segments[1])
        let snapshot = buffer.segments.map(\.id)
        buffer.hold(snapshot)
        buffer.hold(snapshot)
        buffer.append(segments[2]) // First saved segment is already evicted.

        XCTAssertTrue(buffer.remove(snapshot).isEmpty)
        XCTAssertTrue(buffer.release(snapshot).isEmpty)
        XCTAssertEqual(buffer.release(snapshot).map(\.id), snapshot)
        XCTAssertEqual(buffer.segments.map(\.id), [segments[2].id])
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
