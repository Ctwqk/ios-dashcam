import XCTest
@testable import DashCamCore

final class NamingAndMetadataTests: XCTestCase {
    private let fixedID = UUID(uuidString: "AB12CD34-0000-0000-0000-000000000000")!

    func testSegmentFilenameFormat() {
        let name = SegmentNaming.segmentFilename(startTime: referenceDate, id: fixedID, timeZone: utc)
        XCTAssertEqual(name, "seg_20260319_142355_AB12CD34.mp4")
    }

    func testSegmentFilenameRoundTrips() throws {
        let name = SegmentNaming.segmentFilename(startTime: referenceDate, id: fixedID, timeZone: utc)
        let parsed = try XCTUnwrap(SegmentNaming.parseSegmentFilename(name, timeZone: utc))
        XCTAssertEqual(parsed.startTime, referenceDate)
        XCTAssertEqual(parsed.shortID, "AB12CD34")
    }

    func testFilenameDependsOnTheTimeZone() {
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let name = SegmentNaming.segmentFilename(startTime: referenceDate, id: fixedID, timeZone: tokyo)
        XCTAssertEqual(name, "seg_20260319_232355_AB12CD34.mp4")
    }

    func testFilenameIgnoresTheUsersCalendar() {
        // A Buddhist-calendar user would otherwise get year 2569 from a plain DateFormatter.
        let name = SegmentNaming.segmentFilename(startTime: referenceDate, id: fixedID, timeZone: utc)
        XCTAssertTrue(name.hasPrefix("seg_2026"))
    }

    func testSegmentsStartingInTheSameSecondGetDistinctNames() {
        let first = Segment(startTime: referenceDate, timeZone: utc)
        let second = Segment(startTime: referenceDate, timeZone: utc)
        XCTAssertNotEqual(first.filename, second.filename)
    }

    func testParsingRejectsForeignFilenames() {
        let rejected = [
            "",
            "notes.txt",
            "seg_20260319_142355_AB12CD34.mov",
            "seg_20260319_142355.mp4",
            "seg_20260319_142355_XYZ12345.mp4",
            "seg_20260319_142355_AB12CD3.mp4",
            "seg_20261399_142355_AB12CD34.mp4",
            "seg_20260319_256100_AB12CD34.mp4",
            "merged_AB12CD34.mp4"
        ]
        for name in rejected {
            XCTAssertNil(SegmentNaming.parseSegmentFilename(name, timeZone: utc), name)
        }
    }

    func testSegmentInitUsesTheNamingScheme() {
        let segment = Segment(startTime: referenceDate, id: fixedID, timeZone: utc)
        XCTAssertEqual(segment.filename, "seg_20260319_142355_AB12CD34.mp4")
        XCTAssertNil(segment.endTime)
        XCTAssertFalse(segment.isProtected)
        XCTAssertNil(segment.duration)
    }

    func testSegmentDurationIsNeverNegative() {
        var segment = Segment(startTime: referenceDate, timeZone: utc)
        segment.endTime = referenceDate.addingTimeInterval(-5)
        XCTAssertEqual(segment.duration, 0)
        segment.endTime = referenceDate.addingTimeInterval(42)
        XCTAssertEqual(segment.duration, 42)
    }

    func testSegmentIsCodable() throws {
        var segment = makeSegment(startingAt: 0)
        segment.isProtected = true
        let data = try JSONEncoder().encode(segment)
        XCTAssertEqual(try JSONDecoder().decode(Segment.self, from: data), segment)
    }

    func testExportFilenameSanitisesTheLabel() {
        let name = SegmentNaming.exportFilename(label: "Col/li sion!", date: referenceDate, id: fixedID, timeZone: utc)
        XCTAssertEqual(name, "dashcam_collision_20260319_142355_AB12CD34.mp4")
    }

    func testExportFilenameFallsBackWhenTheLabelIsEmpty() {
        let name = SegmentNaming.exportFilename(label: "../", date: referenceDate, id: fixedID, timeZone: utc)
        XCTAssertEqual(name, "dashcam_clip_20260319_142355_AB12CD34.mp4")
    }

    // MARK: - ClipMetadata

    func testClipMetadataSummarisesTheSegments() throws {
        let segments = [
            makeSegment(startingAt: 120, duration: 60),
            makeSegment(startingAt: 0, duration: 60),
            makeSegment(startingAt: 60, duration: 30)
        ]
        let metadata = try XCTUnwrap(ClipMetadata.make(trigger: .collision, segments: segments, id: fixedID))
        XCTAssertEqual(metadata.startDate, referenceDate)
        XCTAssertEqual(metadata.segmentCount, 3)
        XCTAssertEqual(metadata.duration, 150, accuracy: 0.001)
        XCTAssertEqual(metadata.filename(timeZone: utc), "dashcam_collision_20260319_142355_AB12CD34.mp4")
    }

    func testClipMetadataNeedsAtLeastOneSegment() {
        XCTAssertNil(ClipMetadata.make(trigger: .manual, segments: []))
    }

    // MARK: - Speed

    func testSpeedConversion() {
        XCTAssertEqual(SpeedConversion.kilometersPerHour(metersPerSecond: 10), 36, accuracy: 1e-9)
    }

    func testInvalidSpeedReadingsBecomeZero() {
        XCTAssertEqual(SpeedConversion.kilometersPerHour(metersPerSecond: -1), 0)
        XCTAssertEqual(SpeedConversion.kilometersPerHour(metersPerSecond: .nan), 0)
        XCTAssertEqual(SpeedConversion.kilometersPerHour(metersPerSecond: .infinity), 0)
    }
}
