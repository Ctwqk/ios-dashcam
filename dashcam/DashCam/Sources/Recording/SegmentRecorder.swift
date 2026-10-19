import AVFoundation
import Combine
import DashCamCore

protocol SegmentRecorderDelegate: AnyObject {
    func segmentRecorder(_ recorder: SegmentRecorder, didFinishSegment segment: Segment)
    func segmentRecorder(_ recorder: SegmentRecorder, didFailWithError error: Error)
}

/// Turns the camera's frame stream into back-to-back MP4 segments.
///
/// Threading: `isRecording`, `currentSegment` and the rotation timer belong to the main
/// thread. `activeWriter` and `acceptingFrames` belong to `cameraManager.bufferQueue`, the
/// queue that also delivers the frames; every state change that affects them is dispatched
/// onto that queue, so writers are never swapped while a frame is being appended.
final class SegmentRecorder: ObservableObject {
    weak var delegate: SegmentRecorderDelegate?

    @Published private(set) var currentSegment: Segment?
    @Published private(set) var isRecording = false

    /// External processors that want to inspect video frames.
    /// Add/remove from the main thread before starting recording.
    var sampleBufferProcessors: [SampleBufferProcessor] = []

    private let cameraManager: CameraManager
    private let config: DashcamConfig
    private var segmentTimer: Timer?

    // MARK: Confined to cameraManager.bufferQueue

    /// The currently active writer accepting new sample buffers.
    private var activeWriter: SegmentWriter?
    private var acceptingFrames = false
    private let finalizations = OrderedCompletionQueue<Result<Segment, Error>>()
    /// After a writer failure, wait before trying again so a persistent problem
    /// (for example a full disk) cannot spin at the frame rate.
    private var nextWriterAttempt = Date.distantPast
    private static let retryDelay: TimeInterval = 2

    init(cameraManager: CameraManager, config: DashcamConfig) {
        self.cameraManager = cameraManager
        self.config = config
    }

    // MARK: - Public

    func startRecording() {
        guard !isRecording else { return }
        isRecording = true

        // The first SegmentWriter is created lazily on the first video buffer,
        // because we need videoFormatDescription to configure AVAssetWriter.
        cameraManager.setSampleBufferHandlers(
            video: { [weak self] buffer in self?.handleVideoSampleBuffer(buffer) },
            audio: { [weak self] buffer in self?.handleAudioSampleBuffer(buffer) }
        )
        cameraManager.bufferQueue.async { [weak self] in
            self?.acceptingFrames = true
            self?.nextWriterAttempt = .distantPast
        }
    }

    /// Stops recording and finishes the active writer.
    /// The optional `completion` is called on the main queue after the last segment is delivered.
    func stopRecording(completion: (() -> Void)? = nil) {
        isRecording = false
        segmentTimer?.invalidate()
        segmentTimer = nil

        // Unregister callbacks so no more buffers arrive
        cameraManager.setSampleBufferHandlers(video: nil, audio: nil)

        // Take the writer on the queue that appends to it, so we never finish it mid-append.
        cameraManager.bufferQueue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async { completion?() }
                return
            }
            self.acceptingFrames = false
            let writer = self.activeWriter
            self.activeWriter = nil

            if let writer {
                self.finish(writer)
            }
            // Include writers already finalizing from a rotation or an earlier stop.
            self.finalizations.barrier {
                DispatchQueue.main.async { completion?() }
            }
        }
    }

    /// Force-finishes the current segment and continues recording.
    /// The finished segment is delivered via delegate; a new segment starts immediately.
    func finishCurrentSegmentAndContinue(completion: @escaping () -> Void) {
        segmentTimer?.invalidate()
        segmentTimer = nil

        cameraManager.bufferQueue.async { [weak self] in
            guard let self else { return }
            if self.acceptingFrames {
                self.rotateWriter(completion: completion)
            } else {
                // An interruption may have stopped the writer during the impact delay.
                self.finalizations.barrier {
                    DispatchQueue.main.async(execute: completion)
                }
            }
        }
    }

    // MARK: - Sample buffer handling (runs on bufferQueue)

    private func handleVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        // Forward to external processors (per-frame processing capability)
        for processor in sampleBufferProcessors {
            processor.processVideoSampleBuffer(sampleBuffer)
        }

        guard acceptingFrames else { return }

        // Lazy-create the first writer once format descriptions are available
        if activeWriter == nil {
            guard cameraManager.videoFormatDescription != nil, Date() >= nextWriterAttempt else { return }
            createNewWriter()
        }

        guard let writer = activeWriter else { return }
        if !writer.appendVideoBuffer(sampleBuffer), writer.hasFailed {
            Log.recording.error("segment writer failed; starting a new segment")
            rotateWriter()
        }
    }

    private func handleAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        for processor in sampleBufferProcessors {
            processor.processAudioSampleBuffer(sampleBuffer)
        }

        activeWriter?.appendAudioBuffer(sampleBuffer)
    }

    // MARK: - Writer management (must be called on bufferQueue)

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
            nextWriterAttempt = Date().addingTimeInterval(Self.retryDelay)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.segmentRecorder(self, didFailWithError: error)
            }
        }
    }

    /// Swap the active writer: the current one becomes outgoing and a new one is created.
    /// The next incoming buffer goes to the new writer.
    private func rotateWriter(completion: (() -> Void)? = nil) {
        guard acceptingFrames else { return }

        let outgoingWriter = activeWriter
        activeWriter = nil

        // Create the new writer immediately so the next buffer goes to it
        if outgoingWriter?.hasFailed == true {
            // The outgoing writer broke; avoid an immediate retry storm.
            nextWriterAttempt = Date().addingTimeInterval(Self.retryDelay)
        } else {
            createNewWriter()
        }

        if let outgoing = outgoingWriter {
            finish(outgoing, completion: completion)
        } else {
            finalizations.barrier {
                DispatchQueue.main.async { completion?() }
            }
        }
    }

    /// Completion order from AVFoundation is unspecified. Deliver in recording order,
    /// and bind an impact callback to its own writer instead of whichever finishes first.
    private func finish(_ writer: SegmentWriter, completion: (() -> Void)? = nil) {
        let ticket = finalizations.enqueue { [weak self] result in
            DispatchQueue.main.async {
                self?.deliver(result, from: writer)
                completion?()
            }
        }
        writer.finish { [weak self] result in
            guard let self else { return }
            self.cameraManager.bufferQueue.async {
                self.finalizations.complete(ticket, with: result)
            }
        }
    }

    // MARK: - Main thread

    private func deliver(_ result: Result<Segment, Error>, from writer: SegmentWriter) {
        switch result {
        case .success(let segment):
            if FileManager.default.fileExists(atPath: writer.outputURL.path) {
                delegate?.segmentRecorder(self, didFinishSegment: segment)
            }
        case .failure(let error):
            delegate?.segmentRecorder(self, didFailWithError: error)
        }
    }

    private func scheduleRotationTimer() {
        segmentTimer?.invalidate()
        segmentTimer = nil
        guard isRecording else { return }

        segmentTimer = Timer.scheduledTimer(
            withTimeInterval: config.segmentDuration,
            repeats: false
        ) { [weak self] _ in
            guard let self, self.isRecording else { return }
            self.cameraManager.bufferQueue.async { [weak self] in
                self?.rotateWriter()
            }
        }
    }
}
