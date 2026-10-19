import Foundation
@testable import DashCamCore

let utc = TimeZone(identifier: "UTC")!

/// 2026-03-19 14:23:55 UTC
let referenceDate = Date(timeIntervalSince1970: 1_773_930_235)

func makeSegment(
    startingAt offset: TimeInterval,
    duration: TimeInterval? = 60,
    id: UUID = UUID()
) -> Segment {
    var segment = Segment(startTime: referenceDate.addingTimeInterval(offset), id: id, timeZone: utc)
    if let duration {
        segment.endTime = segment.startTime.addingTimeInterval(duration)
    }
    return segment
}

func makeSegments(_ count: Int) -> [Segment] {
    (0..<count).map { makeSegment(startingAt: TimeInterval($0) * 60) }
}
