import AVFoundation
import DashCamCore

/// Wraps a single AVAssetWriter to produce one MP4 segment file.
/// Each instance is used once: create -> append buffers -> finish -> discard.
///
/// Thread safety: sample buffers are appended from `CameraManager.bufferQueue`, while
/// `finish` may be called from there too, but its completion runs on an arbitrary
/// AVFoundation queue. The writer state is therefore guarded by a lock, which also
/// guarantees that no buffer is appended after the inputs were marked as finished
/// (AVFoundation raises an exception in that case).
final class SegmentWriter {

    enum State {
        case idle       // created, not yet started
        case writing    // actively accepting sample buffers
        case finishing  // finishWriting called, waiting for completion
        case finished   // done, file is ready
        case failed(Error)
    }

    enum WriterError: LocalizedError {
        case cannotAddVideoInput
        case startFailed
        case appendFailed
        case alreadyFinishing
        case cancelled

        var errorDescription: String? {
            switch self {
            case .cannotAddVideoInput: return "The video encoder settings are not supported on this device."
            case .startFailed: return "The asset writer could not start."
            case .appendFailed: return "Appending a sample buffer failed."
            case .alreadyFinishing: return "The segment is already being finalized."
            case .cancelled: return "Cancelled"
            }
        }
    }

    let outputURL: URL
    let segment: Segment

    private let lock = NSLock()
    private var stateStorage: State = .idle

    private let assetWriter: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private var audioInput: AVAssetWriterInput?

    var state: State { lock.withLock { stateStorage } }

    var hasFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    // MARK: - Init

    init(outputURL: URL,
         segment: Segment,
         config: DashcamConfig,
         videoFormatDescription: CMFormatDescription,
         audioFormatDescription: CMFormatDescription?) throws {

        self.outputURL = outputURL
        self.segment = segment

        // Remove existing file if any
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        // --- Video input ---
        let codecType: AVVideoCodecType = config.codec == .hevc ? .hevc : .h264
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: codecType,
            AVVideoWidthKey: config.resolution.width,
            AVVideoHeightKey: config.resolution.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: VideoQuality.videoBitRate(
                    resolution: config.resolution,
                    codec: config.codec
                )
            ]
        ]
        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vInput.expectsMediaDataInRealTime = true
        vInput.transform = .identity

        guard writer.canAdd(vInput) else { throw WriterError.cannotAddVideoInput }
        writer.add(vInput)

        // --- Audio input (only when the microphone delivers samples) ---
        if audioFormatDescription != nil {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: VideoQuality.audioBitRate
            ]
            let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            aInput.expectsMediaDataInRealTime = true

            if writer.canAdd(aInput) {
                writer.add(aInput)
                self.audioInput = aInput
            }
        }

        self.assetWriter = writer
        self.videoInput = vInput
    }

    // MARK: - Writing

    /// Appends a video sample buffer, starting the writing session on the first one.
    /// Returns false if the writer is not accepting buffers.
    @discardableResult
    func appendVideoBuffer(_ sampleBuffer: CMSampleBuffer) -> Bool {
        lock.withLock {
            if case .idle = stateStorage {
                // First video buffer: start the writing session
                guard assetWriter.startWriting() else {
                    stateStorage = .failed(assetWriter.error ?? WriterError.startFailed)
                    return false
                }
                assetWriter.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
                stateStorage = .writing
            }

            guard case .writing = stateStorage, videoInput.isReadyForMoreMediaData else { return false }
            if videoInput.append(sampleBuffer) { return true }

            if assetWriter.status == .failed {
                stateStorage = .failed(assetWriter.error ?? WriterError.appendFailed)
            }
            return false
        }
    }

    /// Appends an audio sample buffer. Returns false if the writer is not accepting.
    @discardableResult
    func appendAudioBuffer(_ sampleBuffer: CMSampleBuffer) -> Bool {
        lock.withLock {
            guard case .writing = stateStorage,
                  let audioInput, audioInput.isReadyForMoreMediaData else { return false }
            return audioInput.append(sampleBuffer)
        }
    }

    // MARK: - Finishing

    /// Finalizes the file. The completion is always called exactly once, on an arbitrary queue.
    /// A failed segment's partial file is removed.
    func finish(completion: @escaping (Result<Segment, Error>) -> Void) {
        enum Action {
            case complete(Result<Segment, Error>, removeFile: Bool)
            case finishWriting
        }

        let action: Action = lock.withLock {
            switch stateStorage {
            case .idle:
                // Never received any buffers: there is no file to keep.
                stateStorage = .finished
                return .complete(.success(closedSegment()), removeFile: true)
            case .failed(let error):
                return .complete(.failure(error), removeFile: true)
            case .finishing:
                return .complete(.failure(WriterError.alreadyFinishing), removeFile: false)
            case .finished:
                return .complete(.success(closedSegment()), removeFile: false)
            case .writing:
                stateStorage = .finishing
                videoInput.markAsFinished()
                audioInput?.markAsFinished()
                return .finishWriting
            }
        }

        switch action {
        case .complete(let result, let removeFile):
            if removeFile {
                try? FileManager.default.removeItem(at: outputURL)
            }
            completion(result)

        case .finishWriting:
            assetWriter.finishWriting {
                if let failure = self.assetWriter.error {
                    self.lock.withLock { self.stateStorage = .failed(failure) }
                    try? FileManager.default.removeItem(at: self.outputURL)
                    completion(.failure(failure))
                } else {
                    self.lock.withLock { self.stateStorage = .finished }
                    completion(.success(self.closedSegment()))
                }
            }
        }
    }

    /// Cancels writing and removes the partial file.
    func cancel() {
        lock.withLock {
            if case .writing = stateStorage {
                assetWriter.cancelWriting()
            }
            stateStorage = .failed(WriterError.cancelled)
        }
        try? FileManager.default.removeItem(at: outputURL)
    }

    // MARK: - Private

    private func closedSegment() -> Segment {
        var closed = segment
        closed.endTime = Date()
        return closed
    }
}
