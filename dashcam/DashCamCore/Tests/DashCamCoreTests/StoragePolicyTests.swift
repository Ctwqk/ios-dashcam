import XCTest
@testable import DashCamCore

final class StoragePolicyTests: XCTestCase {
    private let policy = StoragePolicy(
        lowStorageThresholdBytes: 1_000,
        reserveBytes: 500,
        minimumSegments: 2
    )

    func testLowStorageFlagUsesTheThreshold() {
        XCTAssertTrue(policy.isLow(freeBytes: 999))
        XCTAssertFalse(policy.isLow(freeBytes: 1_000))
        XCTAssertFalse(policy.isLow(freeBytes: 50_000))
    }

    func testDefaultThresholdIsOneGibibyte() {
        XCTAssertTrue(StoragePolicy().isLow(freeBytes: StoragePolicy.gibibyte - 1))
        XCTAssertFalse(StoragePolicy().isLow(freeBytes: StoragePolicy.gibibyte))
    }

    func testPlentyOfSpaceKeepsTheConfiguredLoop() {
        let allowed = policy.allowedSegments(configuredMax: 15, currentCount: 15, bufferBytes: 1_500, freeBytes: 500)
        XCTAssertEqual(allowed, 15)
    }

    func testShortfallDropsJustEnoughSegments() {
        // 10 segments of 100 bytes each; 150 bytes short of the reserve -> drop 2.
        let allowed = policy.allowedSegments(configuredMax: 15, currentCount: 10, bufferBytes: 1_000, freeBytes: 350)
        XCTAssertEqual(allowed, 8)
    }

    func testPartialSegmentShortfallRoundsUp() {
        // 1 byte short still means one whole segment has to go.
        let allowed = policy.allowedSegments(configuredMax: 15, currentCount: 10, bufferBytes: 1_000, freeBytes: 499)
        XCTAssertEqual(allowed, 9)
    }

    func testLoopIsNeverShortenedBelowTheMinimum() {
        let allowed = policy.allowedSegments(configuredMax: 15, currentCount: 10, bufferBytes: 100, freeBytes: 0)
        XCTAssertEqual(allowed, 2)
    }

    func testResultNeverExceedsTheConfiguredLoop() {
        let allowed = policy.allowedSegments(configuredMax: 4, currentCount: 10, bufferBytes: 1_000, freeBytes: 450)
        XCTAssertEqual(allowed, 4)
    }

    func testEmptyBufferCannotBeShrunk() {
        let allowed = policy.allowedSegments(configuredMax: 15, currentCount: 0, bufferBytes: 0, freeBytes: 0)
        XCTAssertEqual(allowed, 15)
    }

    func testMinimumDoesNotOverrideASmallerConfiguredLoop() {
        let allowed = policy.allowedSegments(configuredMax: 1, currentCount: 1, bufferBytes: 100, freeBytes: 0)
        XCTAssertEqual(allowed, 1)
    }

    // MARK: - Orphan cleanup

    func testOnlyUntrackedOldSegmentFilesAreOrphans() {
        let cutoff = referenceDate
        let old = referenceDate.addingTimeInterval(-3_600)
        let recent = referenceDate.addingTimeInterval(5)

        let id = UUID()
        let tracked = Segment(startTime: old, id: id, timeZone: utc)
        let orphan = Segment(startTime: old, timeZone: utc)
        let fresh = Segment(startTime: recent, timeZone: utc)

        let files = [
            StoredFile(name: tracked.filename, modificationDate: old, size: 10),
            StoredFile(name: orphan.filename, modificationDate: old, size: 10),
            StoredFile(name: fresh.filename, modificationDate: recent, size: 10),
            StoredFile(name: "notes.txt", modificationDate: old, size: 10),
            StoredFile(name: "merged_AB12CD34.mp4", modificationDate: old, size: 10)
        ]

        let result = policy.orphanedSegmentFiles(
            in: files,
            trackedFilenames: [tracked.filename],
            cutoff: cutoff,
            timeZone: utc
        )

        XCTAssertEqual(result.map(\.name), [orphan.filename])
    }

    func testNothingIsOrphanedInAnEmptyDirectory() {
        XCTAssertTrue(policy.orphanedSegmentFiles(in: [], trackedFilenames: [], cutoff: referenceDate).isEmpty)
    }
}
