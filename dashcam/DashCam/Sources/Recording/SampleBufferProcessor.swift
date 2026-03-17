import AVFoundation

/// Protocol for objects that want to process individual video/audio frames.
///
/// Callbacks arrive on CameraManager.bufferQueue (serial, high priority).
/// Implementations **must return quickly** — dispatch heavy work to a
/// background queue. The CMSampleBuffer is only valid during the callback;
/// retain the CVPixelBuffer or copy if you need it later.
protocol SampleBufferProcessor: AnyObject {
    /// Called for every video sample buffer captured by the camera.
    func processVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer)

    /// Called for every audio sample buffer captured. Optional.
    func processAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer)
}

// Default empty implementation for audio — most processors only care about video.
extension SampleBufferProcessor {
    func processAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {}
}
