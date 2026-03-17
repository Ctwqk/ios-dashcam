import AVFoundation
import Combine

protocol SegmentRecorderDelegate: AnyObject {
    func segmentRecorder(_ recorder: SegmentRecorder, didFinishSegment segment: Segment)
    func segmentRecorder(_ recorder: SegmentRecorder, didFailWithError error: Error)
}

final class SegmentRecorder: ObservableObject {
    weak var delegate: SegmentRecorderDelegate?

    @Published private(set) var currentSegment: Segment?
    @Published private(set) var isRecording = false

    /// One-shot callback fired on the main queue after the next segment finishes writing.
    var onNextSegmentFinished: (() -> Void)?

    /// External processors that want to inspect video frames.
    /// Add/remove from the main thread before starting recording.
    var sampleBufferProcessors: [SampleBufferProcessor] = []

    private let cameraManager: CameraManager
    private let config: DashcamConfig
    private var segmentTimer: Timer?

    /// The currently active writer accepting new sample buffers.
    private var activeWriter: SegmentWriter?

    init(cameraManager: CameraManager, config: DashcamConfig) {
        self.cameraManager = cameraManager
        self.config = config
    }

    // MARK: - Public

    func startRecording() {
        guard !isRecording else { return }
        isRecording = true

        // Register for sample buffer callbacks from CameraManager.
        // The first SegmentWriter is created lazily on the first video buffer,
        // because we need videoFormatDescription to configure AVAssetWriter.
        cameraManager.onVideoSampleBuffer = { [weak self] buffer in
            self?.handleVideoSampleBuffer(buffer)
        }
        cameraManager.onAudioSampleBuffer = { [weak self] buffer in
            self?.handleAudioSampleBuffer(buffer)
        }
    }

    /// Stops recording and finishes the active writer.
    /// The optional `completion` is called on the main queue after the last segment is delivered.
    func stopRecording(completion: (() -> Void)? = nil) {
        guard isRecording else {
            completion?()
            return
        }
        isRecording = false
        segmentTimer?.invalidate()
        segmentTimer = nil

        // Unregister callbacks so no more buffers arrive
        cameraManager.onVideoSampleBuffer = nil
        cameraManager.onAudioSampleBuffer = nil

        // Finish active writer and deliver last segment
        guard let writer = activeWriter else {
            completion?()
            return
        }
        activeWriter = nil

        writer.finish { [weak self] result in
            DispatchQueue.main.async {
                guard let self else {
                    completion?()
                    return
                }
                switch result {
                case .success(let segment):
                    if FileManager.default.fileExists(atPath: writer.outputURL.path) {
                        self.delegate?.segmentRecorder(self, didFinishSegment: segment)
                    }
                case .failure(let error):
                    self.delegate?.segmentRecorder(self, didFailWithError: error)
                }
                completion?()
            }
        }
    }

    /// Force-finishes the current segment and continues recording.
    /// The finished segment is delivered via delegate; a new segment starts immediately.
    func finishCurrentSegmentAndContinue() {
        guard isRecording else { return }
        segmentTimer?.invalidate()
        segmentTimer = nil

        // Dispatch to bufferQueue to safely swap writers
        cameraManager.bufferQueue.async { [weak self] in
            self?.rotateWriter()
        }
    }

    // MARK: - Private: Sample Buffer Handling (runs on bufferQueue)

    private func handleVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        // Forward to external processors (per-frame processing capability)
        for processor in sampleBufferProcessors {
            processor.processVideoSampleBuffer(sampleBuffer)
        }

        // Lazy-create the first writer once format descriptions are available
        if activeWriter == nil && isRecording {
            guard cameraManager.videoFormatDescription != nil else { return }
            createNewWriter()
        }

        activeWriter?.appendVideoBuffer(sampleBuffer)
    }

    private func handleAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        for processor in sampleBufferProcessors {
            processor.processAudioSampleBuffer(sampleBuffer)
        }

        activeWriter?.appendAudioBuffer(sampleBuffer)
    }

    // MARK: - Private: Writer Management (must be called on bufferQueue)

    private func createNewWriter() {
        let segment = Segment()
        let dir = LoopBufferManager.segmentsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let outputURL = dir.appendingPathComponent(segment.filename)

        guard let videoFmt = cameraManager.videoFormatDescription else { return }

        do {
            let writer = try SegmentWriter(
                outputURL: outputURL,
                segment: segment,
                config: config,
                videoFormatDescription: videoFmt,
                audioFormatDescription: cameraManager.audioFormatDescription
            )
            activeWriter = writer

            DispatchQueue.main.async { [weak self] in
                self?.currentSegment = segment
                self?.scheduleRotationTimer()
            }
        } catch {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.segmentRecorder(self, didFailWithError: error)
            }
        }
    }

    /// Atomically swap active writer: current becomes outgoing, new one is created.
    /// The next incoming buffer goes to the new writer -> zero frame loss.
    private func rotateWriter() {
        guard isRecording else { return }

        let outgoingWriter = activeWriter
        activeWriter = nil

        // Create new writer immediately so the next buffer goes to it
        createNewWriter()

        // Finish the outgoing writer asynchronously
        guard let outgoing = outgoingWriter else { return }
        outgoing.finish { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let segment):
                    if FileManager.default.fileExists(atPath: outgoing.outputURL.path) {
                        self.delegate?.segmentRecorder(self, didFinishSegment: segment)
                    }
                case .failure(let error):
                    self.delegate?.segmentRecorder(self, didFailWithError: error)
                }

                // Fire one-shot callback
                if let callback = self.onNextSegmentFinished {
                    self.onNextSegmentFinished = nil
                    callback()
                }
            }
        }
    }

    private func scheduleRotationTimer() {
        segmentTimer?.invalidate()
        segmentTimer = Timer.scheduledTimer(
            withTimeInterval: config.segmentDuration,
            repeats: false
        ) { [weak self] _ in
            guard let self, self.isRecording else { return }
            self.cameraManager.bufferQueue.async {
                self.rotateWriter()
            }
        }
    }
}
