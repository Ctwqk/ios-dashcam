import AVFoundation

/// Wraps a single AVAssetWriter to produce one MP4 segment file.
/// Each instance is used once: create -> append buffers -> finish -> discard.
///
/// Thread safety: all append calls must come from the same serial queue
/// (CameraManager.bufferQueue). The `finish` completion is called on that queue.
final class SegmentWriter {

    enum State {
        case idle       // created, not yet started
        case writing    // actively accepting sample buffers
        case finishing  // finishWriting called, waiting for completion
        case finished   // done, file is ready
        case failed(Error)
    }

    private(set) var state: State = .idle

    let outputURL: URL
    let segment: Segment

    private let assetWriter: AVAssetWriter
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var hasStartedSession = false

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

        self.assetWriter = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        // --- Video input ---
        let codecType: AVVideoCodecType = config.codec == .hevc ? .hevc : .h264
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: codecType,
            AVVideoWidthKey: config.resolution.width,
            AVVideoHeightKey: config.resolution.height,
        ]
        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vInput.expectsMediaDataInRealTime = true
        vInput.transform = .identity

        if assetWriter.canAdd(vInput) {
            assetWriter.add(vInput)
            self.videoInput = vInput
        }

        // --- Audio input ---
        if audioFormatDescription != nil {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64000,
            ]
            let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            aInput.expectsMediaDataInRealTime = true

            if assetWriter.canAdd(aInput) {
                assetWriter.add(aInput)
                self.audioInput = aInput
            }
        }
    }

    // MARK: - Writing

    /// Appends a video sample buffer. Returns false if the writer is not accepting.
    @discardableResult
    func appendVideoBuffer(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard case .idle = state, !hasStartedSession else {
            return appendVideoBufferInternal(sampleBuffer)
        }

        // First video buffer: start the writing session
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        assetWriter.startWriting()
        assetWriter.startSession(atSourceTime: timestamp)
        hasStartedSession = true
        state = .writing

        return appendVideoBufferInternal(sampleBuffer)
    }

    /// Appends an audio sample buffer. Returns false if the writer is not accepting.
    @discardableResult
    func appendAudioBuffer(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard case .writing = state else { return false }
        guard let audioInput, audioInput.isReadyForMoreMediaData else { return false }
        return audioInput.append(sampleBuffer)
    }

    // MARK: - Finishing

    /// Finalizes the file. Completion is always called.
    func finish(completion: @escaping (Result<Segment, Error>) -> Void) {
        switch state {
        case .idle:
            // Never received any buffers — nothing to write
            state = .finished
            try? FileManager.default.removeItem(at: outputURL)
            var seg = segment
            seg.endTime = Date()
            completion(.success(seg))
            return

        case .failed(let err):
            completion(.failure(err))
            return

        case .finishing, .finished:
            var seg = segment
            seg.endTime = Date()
            completion(.success(seg))
            return

        case .writing:
            break
        }

        state = .finishing
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()

        assetWriter.finishWriting { [weak self] in
            guard let self else { return }
            if let error = self.assetWriter.error {
                self.state = .failed(error)
                completion(.failure(error))
            } else {
                self.state = .finished
                var finishedSegment = self.segment
                finishedSegment.endTime = Date()
                completion(.success(finishedSegment))
            }
        }
    }

    /// Cancels writing and removes the partial file.
    func cancel() {
        assetWriter.cancelWriting()
        state = .failed(NSError(domain: "SegmentWriter", code: -1,
                                userInfo: [NSLocalizedDescriptionKey: "Cancelled"]))
        try? FileManager.default.removeItem(at: outputURL)
    }

    // MARK: - Private

    private func appendVideoBufferInternal(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard case .writing = state else { return false }
        guard let videoInput, videoInput.isReadyForMoreMediaData else { return false }
        return videoInput.append(sampleBuffer)
    }
}
