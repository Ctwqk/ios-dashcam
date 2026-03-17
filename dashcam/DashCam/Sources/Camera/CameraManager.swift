import AVFoundation
import UIKit

final class CameraManager: NSObject, ObservableObject {
    let captureSession = AVCaptureSession()

    /// Serial queue for all sample buffer delegate callbacks.
    /// SegmentWriter append calls also happen on this queue — thread-safe without locks.
    let bufferQueue = DispatchQueue(label: "com.dashcam.bufferQueue", qos: .userInteractive)

    /// Called on bufferQueue for every video frame.
    var onVideoSampleBuffer: ((CMSampleBuffer) -> Void)?
    /// Called on bufferQueue for every audio sample.
    var onAudioSampleBuffer: ((CMSampleBuffer) -> Void)?

    /// Format descriptions captured from the first sample buffers.
    /// SegmentWriter needs these to configure AVAssetWriter inputs.
    private(set) var videoFormatDescription: CMFormatDescription?
    private(set) var audioFormatDescription: CMFormatDescription?

    @Published var isSessionRunning = false
    @Published var error: String?

    private let sessionQueue = DispatchQueue(label: "com.dashcam.session")
    private var videoDeviceInput: AVCaptureDeviceInput?
    private var isConfigured = false
    private var thermalObserver: NSObjectProtocol?
    private var currentConfig: DashcamConfig?

    func configureAndStart(with config: DashcamConfig, completion: (() -> Void)? = nil) {
        currentConfig = config
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.setupSession(config: config)
            if !self.captureSession.isRunning {
                self.captureSession.startRunning()
            }
            DispatchQueue.main.async {
                self.isSessionRunning = self.captureSession.isRunning
                self.startThermalMonitoring()
                completion?()
            }
        }
    }

    // MARK: - Private

    private func setupSession(config: DashcamConfig) {
        guard !isConfigured else { return }
        isConfigured = true

        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }

        captureSession.sessionPreset = config.resolution == .hd720p
            ? .hd1280x720
            : .hd1920x1080

        // Video input — prefer wide-angle camera (default)
        let camera: AVCaptureDevice? =
            AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)

        guard let camera else {
            setError("No back camera available")
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: camera)
            if captureSession.canAddInput(input) {
                captureSession.addInput(input)
                videoDeviceInput = input
            }

            // Configure frame rate and power-saving options
            try camera.lockForConfiguration()

            let desiredFPS = CMTimeMake(value: 1, timescale: Int32(config.frameRate))
            camera.activeVideoMinFrameDuration = desiredFPS
            camera.activeVideoMaxFrameDuration = desiredFPS

            // Disable HDR to reduce CPU/heat
            if camera.responds(to: #selector(getter: AVCaptureDevice.automaticallyAdjustsVideoHDREnabled)) {
                camera.automaticallyAdjustsVideoHDREnabled = false
                camera.isVideoHDREnabled = false
            }

            camera.unlockForConfiguration()
        } catch {
            setError("Camera setup failed: \(error.localizedDescription)")
            return
        }

        // Audio input
        if let mic = AVCaptureDevice.default(for: .audio),
           let audioInput = try? AVCaptureDeviceInput(device: mic),
           captureSession.canAddInput(audioInput) {
            captureSession.addInput(audioInput)
        }

        // --- Video data output (frame-by-frame) ---
        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: bufferQueue)
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]

        if captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)

            if let connection = videoOutput.connection(with: .video) {
                // Landscape orientation
                if #available(iOS 17.0, *) {
                    if connection.isVideoRotationAngleSupported(0) {
                        connection.videoRotationAngle = 0
                    }
                } else {
                    if connection.isVideoOrientationSupported {
                        connection.videoOrientation = .landscapeRight
                    }
                }

                // Disable video stabilization to reduce CPU
                if connection.isVideoStabilizationSupported {
                    connection.preferredVideoStabilizationMode = .off
                }
            }
        }

        // --- Audio data output ---
        let audioOutput = AVCaptureAudioDataOutput()
        audioOutput.setSampleBufferDelegate(self, queue: bufferQueue)

        if captureSession.canAddOutput(audioOutput) {
            captureSession.addOutput(audioOutput)
        }
    }

    private func setError(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.error = message
        }
    }

    // MARK: - Thermal Monitoring

    private func startThermalMonitoring() {
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleThermalChange()
        }
    }

    private func handleThermalChange() {
        guard let camera = videoDeviceInput?.device,
              let config = currentConfig else { return }

        let state = ProcessInfo.processInfo.thermalState
        let targetFPS: Int

        switch state {
        case .nominal, .fair:
            targetFPS = config.frameRate          // full rate (default 30)
        case .serious:
            targetFPS = max(15, config.frameRate / 2) // halve, floor 15
        case .critical:
            targetFPS = 15                         // minimum usable
        @unknown default:
            targetFPS = config.frameRate
        }

        sessionQueue.async {
            do {
                try camera.lockForConfiguration()
                let duration = CMTimeMake(value: 1, timescale: Int32(targetFPS))
                camera.activeVideoMinFrameDuration = duration
                camera.activeVideoMaxFrameDuration = duration
                camera.unlockForConfiguration()
            } catch {
                print("Thermal frame rate adjustment failed: \(error)")
            }
        }
    }

    func stopThermalMonitoring() {
        if let observer = thermalObserver {
            NotificationCenter.default.removeObserver(observer)
            thermalObserver = nil
        }
    }

    deinit {
        stopThermalMonitoring()
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate & AVCaptureAudioDataOutputSampleBufferDelegate

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate,
                          AVCaptureAudioDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {

        if output is AVCaptureVideoDataOutput {
            if videoFormatDescription == nil {
                videoFormatDescription = CMSampleBufferGetFormatDescription(sampleBuffer)
            }
            onVideoSampleBuffer?(sampleBuffer)

        } else if output is AVCaptureAudioDataOutput {
            if audioFormatDescription == nil {
                audioFormatDescription = CMSampleBufferGetFormatDescription(sampleBuffer)
            }
            onAudioSampleBuffer?(sampleBuffer)
        }
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // Dropped frames — could log for diagnostics
    }
}
