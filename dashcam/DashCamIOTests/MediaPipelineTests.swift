import AVFoundation
import DashCamCore
import XCTest

final class MediaPipelineTests: XCTestCase {
    @MainActor
    func testSuccessfulSavePreservesFootageAddedDuringExport() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = LoopBufferManager(config: DashcamConfig(), directory: directory)
        let saved = Segment()
        let newer = Segment()
        for segment in [saved, newer] {
            try Data([0]).write(to: directory.appendingPathComponent(segment.filename))
        }
        manager.addSegment(saved)
        let request = try XCTUnwrap(manager.beginExport(trigger: .manual))
        manager.addSegment(newer)
        manager.endExport(request, clearBuffer: true)

        // Wait for the queued deletion, then inspect both bookkeeping and actual files.
        let savedURL = directory.appendingPathComponent(saved.filename)
        for _ in 0..<100 where FileManager.default.fileExists(atPath: savedURL.path) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(manager.segments.map(\.id), [newer.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: savedURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(newer.filename).path))
    }

    func testWriterProducesPlayableVideoAndRejectsAppendAfterFinish() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (writer, sample) = try await writeSegment(in: directory)
        let asset = AVURLAsset(url: writer.outputURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1)
        let duration = try await asset.load(.duration)
        XCTAssertGreaterThan(duration.seconds, 0)
        XCTAssertFalse(writer.appendVideoBuffer(sample))
        XCTAssertFalse(writer.hasFailed)
    }

    func testMergeIncludesBothSilentSegments() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try await writeSegment(in: directory).0
        let second = try await writeSegment(in: directory).0
        let exports = directory.appendingPathComponent("exports")
        let manager = FileProtectionManager(directory: exports)
        let merged = try await manager.mergeFiles([first.outputURL, second.outputURL], outputName: "merged.mp4")
        let firstDuration = try await AVURLAsset(url: first.outputURL).load(.duration)
        let secondDuration = try await AVURLAsset(url: second.outputURL).load(.duration)
        let mergedDuration = try await AVURLAsset(url: merged).load(.duration)
        XCTAssertEqual(mergedDuration.seconds, firstDuration.seconds + secondDuration.seconds, accuracy: 0.05)
    }

    func testUnreadableSegmentFailsTheWholeMergeAndKeepsSources() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = try await writeSegment(in: directory).0
        let corrupt = directory.appendingPathComponent("corrupt.mp4")
        try Data("not a video".utf8).write(to: corrupt)
        let exports = directory.appendingPathComponent("exports")
        let manager = FileProtectionManager(directory: exports)
        do {
            _ = try await manager.mergeFiles([writer.outputURL, corrupt], outputName: "partial.mp4")
            XCTFail("a partial clip must never be reported as a successful save")
        } catch {
            XCTAssertTrue(FileManager.default.fileExists(atPath: writer.outputURL.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: corrupt.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: exports.appendingPathComponent("partial.mp4").path))
        }
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pu-review-iosdashcam-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writeSegment(in directory: URL) async throws -> (SegmentWriter, CMSampleBuffer) {
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(
            kCFAllocatorDefault, 1280, 720, kCVPixelFormatType_32BGRA, nil, &pixelBuffer
        ), kCVReturnSuccess)
        let pixels = try XCTUnwrap(pixelBuffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        if let address = CVPixelBufferGetBaseAddress(pixels) {
            memset(address, 0, CVPixelBufferGetBytesPerRow(pixels) * CVPixelBufferGetHeight(pixels))
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixels, formatDescriptionOut: &format
        ), noErr)
        let description = try XCTUnwrap(format)
        let segment = Segment()
        let writer = try SegmentWriter(
            outputURL: directory.appendingPathComponent(segment.filename), segment: segment,
            config: DashcamConfig(codec: .h264), videoFormatDescription: description, audioFormatDescription: nil
        )
        var lastSample: CMSampleBuffer?
        for index in 0..<6 {
            var timing = CMSampleTimingInfo(
                duration: CMTime(value: 1, timescale: 30),
                presentationTimeStamp: CMTime(value: Int64(index), timescale: 30), decodeTimeStamp: .invalid
            )
            var sample: CMSampleBuffer?
            XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: pixels, formatDescription: description,
                sampleTiming: &timing, sampleBufferOut: &sample
            ), noErr)
            let buffer = try XCTUnwrap(sample)
            var appended = writer.appendVideoBuffer(buffer)
            for _ in 0..<100 where !appended && !writer.hasFailed {
                try await Task.sleep(nanoseconds: 10_000_000)
                appended = writer.appendVideoBuffer(buffer)
            }
            XCTAssertTrue(appended)
            lastSample = buffer
        }
        let _: Segment = try await withCheckedThrowingContinuation { continuation in
            writer.finish { continuation.resume(with: $0) }
        }
        return (writer, try XCTUnwrap(lastSample))
    }
}
