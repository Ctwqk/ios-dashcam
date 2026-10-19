import XCTest
@testable import DashCamCore

final class ConfigAndQualityTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "DashCamCoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testDefaults() {
        let config = DashcamConfig()
        XCTAssertEqual(config.bufferMinutes, 15)
        XCTAssertEqual(config.maxSegments, 15)
        XCTAssertEqual(config.collisionThreshold, 3.0)
        XCTAssertEqual(config.maxBufferDuration, 900)
    }

    func testMaxSegmentsFollowsTheSegmentLength() {
        var config = DashcamConfig(bufferMinutes: 30)
        XCTAssertEqual(config.maxSegments, 30)
        config.segmentDuration = 30
        XCTAssertEqual(config.maxSegments, 60)
    }

    func testLoadWithoutSavedValuesReturnsDefaults() {
        XCTAssertEqual(DashcamConfig.load(from: defaults), DashcamConfig())
    }

    func testSaveAndLoadRoundTrip() {
        var config = DashcamConfig()
        config.bufferMinutes = 120
        config.collisionThreshold = 4.5
        config.save(to: defaults)

        let loaded = DashcamConfig.load(from: defaults)
        XCTAssertEqual(loaded.bufferMinutes, 120)
        XCTAssertEqual(loaded.collisionThreshold, 4.5)
    }

    func testOutOfRangeSavedValuesAreIgnored() {
        defaults.set(5, forKey: DashcamConfig.bufferMinutesKey)
        defaults.set(99.0, forKey: DashcamConfig.collisionThresholdKey)
        let loaded = DashcamConfig.load(from: defaults)
        XCTAssertEqual(loaded.bufferMinutes, 15)
        XCTAssertEqual(loaded.collisionThreshold, 3.0)

        defaults.set(361, forKey: DashcamConfig.bufferMinutesKey)
        defaults.set(1.0, forKey: DashcamConfig.collisionThresholdKey)
        XCTAssertEqual(DashcamConfig.load(from: defaults).bufferMinutes, 15)
        XCTAssertEqual(DashcamConfig.load(from: defaults).collisionThreshold, 3.0)
    }

    func testRangeBoundariesAreAccepted() {
        defaults.set(360, forKey: DashcamConfig.bufferMinutesKey)
        defaults.set(1.5, forKey: DashcamConfig.collisionThresholdKey)
        let loaded = DashcamConfig.load(from: defaults)
        XCTAssertEqual(loaded.bufferMinutes, 360)
        XCTAssertEqual(loaded.collisionThreshold, 1.5)
    }

    func testEveryBufferOptionIsWithinTheValidRange() {
        for option in BufferDurationOption.allCases {
            XCTAssertTrue(DashcamConfig.bufferMinutesRange.contains(option.rawValue), "\(option)")
        }
    }

    // MARK: - Quality / estimates

    func testHEVCIsLighterThanH264AtTheSameResolution() {
        for resolution in VideoResolution.allCases {
            XCTAssertLessThan(
                VideoQuality.videoBitRate(resolution: resolution, codec: .hevc),
                VideoQuality.videoBitRate(resolution: resolution, codec: .h264)
            )
        }
    }

    func test1080pNeedsMoreBitrateThan720p() {
        for codec in VideoCodec.allCases {
            XCTAssertGreaterThan(
                VideoQuality.videoBitRate(resolution: .hd1080p, codec: codec),
                VideoQuality.videoBitRate(resolution: .hd720p, codec: codec)
            )
        }
    }

    func testEstimatedBytesForOneMinuteOf720pHEVC() {
        // (2_500_000 + 64_000) bit/s * 60 s / 8 = 19_230_000 bytes
        let bytes = VideoQuality.estimatedBytes(duration: 60, resolution: .hd720p, codec: .hevc)
        XCTAssertEqual(bytes, 19_230_000)
    }

    func testEstimateScalesLinearlyAndHandlesZero() {
        let one = VideoQuality.estimatedBytes(duration: 60, resolution: .hd1080p, codec: .h264)
        let ten = VideoQuality.estimatedBytes(duration: 600, resolution: .hd1080p, codec: .h264)
        XCTAssertEqual(ten, one * 10)
        XCTAssertEqual(VideoQuality.estimatedBytes(duration: 0, resolution: .hd720p, codec: .hevc), 0)
        XCTAssertEqual(VideoQuality.estimatedBytes(duration: -3, resolution: .hd720p, codec: .hevc), 0)
    }

    func testConfigEstimateCoversTheWholeBuffer() {
        let config = DashcamConfig(bufferMinutes: 60)
        XCTAssertEqual(config.estimatedBufferBytes, 19_230_000 * 60)
    }

    func testResolutionDimensions() {
        XCTAssertEqual(VideoResolution.hd720p.width, 1280)
        XCTAssertEqual(VideoResolution.hd720p.height, 720)
        XCTAssertEqual(VideoResolution.hd1080p.width, 1920)
        XCTAssertEqual(VideoResolution.hd1080p.height, 1080)
    }

    // MARK: - Thermal

    func testNominalAndFairKeepFullFrameRate() {
        XCTAssertEqual(ThermalPolicy.targetFrameRate(baseFrameRate: 30, thermalLevel: .nominal), 30)
        XCTAssertEqual(ThermalPolicy.targetFrameRate(baseFrameRate: 30, thermalLevel: .fair), 30)
    }

    func testSeriousHalvesTheFrameRateWithAFloor() {
        XCTAssertEqual(ThermalPolicy.targetFrameRate(baseFrameRate: 60, thermalLevel: .serious), 30)
        XCTAssertEqual(ThermalPolicy.targetFrameRate(baseFrameRate: 30, thermalLevel: .serious), 15)
        XCTAssertEqual(ThermalPolicy.targetFrameRate(baseFrameRate: 24, thermalLevel: .serious), 15)
    }

    func testCriticalUsesTheMinimumUsableFrameRate() {
        XCTAssertEqual(ThermalPolicy.targetFrameRate(baseFrameRate: 30, thermalLevel: .critical), 15)
    }

    func testThrottlingNeverRaisesTheFrameRateAboveTheConfiguredOne() {
        XCTAssertEqual(ThermalPolicy.targetFrameRate(baseFrameRate: 10, thermalLevel: .serious), 10)
        XCTAssertEqual(ThermalPolicy.targetFrameRate(baseFrameRate: 10, thermalLevel: .critical), 10)
    }
}
