import AVFoundation
import UIKit
import DashCamCore

/// Why the camera cannot be used. Shown in the UI as an empty-state card.
enum CameraError: Equatable {
    case permissionDenied
    case cameraUnavailable
    case setupFailed(String)

    var message: String {
        switch self {
        case .permissionDenied:
            return NSLocalizedString("camera.error.denied", comment: "")
        case .cameraUnavailable:
            return NSLocalizedString("camera.error.unavailable", comment: "")
        case .setupFailed(let detail):
            return String(format: NSLocalizedString("camera.error.setupFailed %@", comment: ""), detail)
        }
    }

    /// Whether the user can fix the problem in the system Settings app.
    var canOpenSettings: Bool { self == .permissionDenied }
}

final class CameraManager: NSObject, ObservableObject {
    let captureSession = AVCaptureSession()

    /// Serial queue for all sample buffer delegate callbacks.
    /// SegmentWriter append calls also happen on this queue, so they need no extra locking.
    let bufferQueue = DispatchQueue(label: "com.dashcam.bufferQueue", qos: .userInteractive)

    /// Format descriptions captured from the first sample buffers.
    /// SegmentWriter needs these to configure AVAssetWriter inputs.
    /// Written and read on `bufferQueue` only.
    private(set) var videoFormatDescription: CMFormatDescription?
    private(set) var audioFormatDescription: CMFormatDescription?

    @Published private(set) var isSessionRunning = false
    @Published private(set) var error: CameraError?

    // Both handlers are confined to bufferQueue; use setSampleBufferHandlers to change them.
    private var onVideoSampleBuffer: ((CMSampleBuffer) -> Void)?
    private var onAudioSampleBuffer: ((CMSampleBuffer) -> Void)?

    private let sessionQueue = DispatchQueue(label: "com.dashcam.session")
    private var videoDeviceInput: AVCaptureDeviceInput?
    private var isConfigured = false
    private var thermalObserver: NSObjectProtocol?
    private var runtimeErrorObserver: NSObjectProtocol?
    private var currentConfig: DashcamConfig?

    // MARK: - Public

    /// Registers (or clears, with `nil`) the per-frame callbacks. They are invoked on `bufferQueue`.
    /// The change itself is applied on `bufferQueue`, so it is ordered with respect to frame delivery.
    func setSampleBufferHandlers(
        video: ((CMSampleBuffer) -> Void)?,
        audio: ((CMSampleBuffer) -> Void)?
    ) {
        bufferQueue.async { [weak self] in
            self?.onVideoSampleBuffer = video
            self?.onAudioSampleBuffer = audio
        }
    }

    /// Cheap check that never shows a permission prompt: surfaces a missing camera or a denied
    /// permission in the UI up front instead of after the first tap on Record.
    func refreshAvailability() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .denied, .restricted:
            error = .permissionDenied
            return
        default:
            break
        }

        if Self.backCamera() == nil {
            error = .cameraUnavailable
        } else if error == .permissionDenied || error == .cameraUnavailable {
            error = nil
        }
    }

    /// Asks for camera (required) and microphone (optional) access, configures the session
    /// once and starts it. `completion` runs on the main queue with `true` if the session is running.
    func configureAndStart(with config: DashcamConfig, completion: @escaping (Bool) -> Void) {
        ensureAccess(for: .video) { [weak self] videoGranted in
            guard let self else { return }
            guard videoGranted else {
                self.error = .permissionDenied
                completion(false)
                return
            }

            // Without microphone access the footage is simply recorded without audio.
            self.ensureAccess(for: .audio) { [weak self] audioGranted in
                guard let self else { return }
                self.sessionQueue.async {
                    self.currentConfig = config
                    let failure = self.setupSession(config: config, includeAudio: audioGranted)
                    if failure == nil, !self.captureSession.isRunning {
                        self.captureSession.startRunning()
                    }
                    let isRunning = self.captureSession.isRunning

                    DispatchQueue.main.async {
                        self.error = failure
                        self.isSessionRunning = isRunning
                        if isRunning {
                            self.startThermalMonitoring()
                            self.startRuntimeErrorObservation()
                        }
                        completion(isRunning)
                    }
                }
            }
        }
    }

    // MARK: - Permissions

    private func ensureAccess(for mediaType: AVMediaType, completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: mediaType) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }

    // MARK: - Session setup (runs on sessionQueue)

    private static func backCamera() -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    }

    /// Returns `nil` on success, or the reason the session could not be configured.
    /// `isConfigured` is only set on success, so a failed attempt can be retried cleanly.
    private func setupSession(config: DashcamConfig, includeAudio: Bool) -> CameraError? {
        guard !isConfigured else { return nil }

        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }

        captureSession.sessionPreset = config.resolution == .hd720p
            ? .hd1280x720
            : .hd1920x1080

        // Video input: wide-angle back camera
        guard let camera = Self.backCamera() else { return .cameraUnavailable }

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: camera)
        } catch {
            return .setupFailed(error.localizedDescription)
        }
        guard captureSession.canAddInput(input) else {
            return .setupFailed("cannot add camera input")
        }
        captureSession.addInput(input)
        videoDeviceInput = input

        configureDevice(camera, frameRate: ThermalPolicy.targetFrameRate(
            baseFrameRate: config.frameRate,
            thermalLevel: ThermalLevel(ProcessInfo.processInfo.thermalState)
        ))

        // Audio input (optional)
        if includeAudio,
           let mic = AVCaptureDevice.default(for: .audio),
           let audioInput = try? AVCaptureDeviceInput(device: mic),
           captureSession.canAddInput(audioInput) {
            captureSession.addInput(audioInput)
        }

        // Video data output (frame by frame)
        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: bufferQueue)
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]

        guard captureSession.canAddOutput(videoOutput) else {
            rollbackConfiguration()
            return .setupFailed("cannot add video output")
        }
        captureSession.addOutput(videoOutput)

        if let connection = videoOutput.connection(with: .video) {
            // Landscape orientation
            if connection.isVideoRotationAngleSupported(0) {
                connection.videoRotationAngle = 0
            }

            // Disable video stabilization to reduce CPU
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = .off
            }
        }

        // Audio data output
        let audioOutput = AVCaptureAudioDataOutput()
        audioOutput.setSampleBufferDelegate(self, queue: bufferQueue)
        if captureSession.canAddOutput(audioOutput) {
            captureSession.addOutput(audioOutput)
        }

        isConfigured = true
        return nil
    }

    /// Frame rate and power-saving options. Failing to lock the device is not fatal:
    /// recording still works at the format's default frame rate.
    private func configureDevice(_ camera: AVCaptureDevice, frameRate: Int) {
        do {
            try camera.lockForConfiguration()
            defer { camera.unlockForConfiguration() }

            let duration = CMTimeMake(value: 1, timescale: Int32(frameRate))
            camera.activeVideoMinFrameDuration = duration
            camera.activeVideoMaxFrameDuration = duration

            // Disable HDR to reduce CPU/heat (only formats that support it expose the switch)
            if camera.activeFormat.isVideoHDRSupported {
                camera.automaticallyAdjustsVideoHDREnabled = false
                camera.isVideoHDREnabled = false
            }
        } catch {
            Log.camera.error("could not configure camera device: \(error.localizedDescription)")
        }
    }

    private func rollbackConfiguration() {
        captureSession.inputs.forEach { captureSession.removeInput($0) }
        captureSession.outputs.forEach { captureSession.removeOutput($0) }
        videoDeviceInput = nil
    }

    // MARK: - Thermal Monitoring

    private func startThermalMonitoring() {
        handleThermalChange()
        guard thermalObserver == nil else { return }
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleThermalChange()
        }
    }

    private func handleThermalChange() {
        sessionQueue.async { [weak self] in
            guard let self, let camera = self.videoDeviceInput?.device,
                  let config = self.currentConfig else { return }
            let targetFPS = ThermalPolicy.targetFrameRate(
                baseFrameRate: config.frameRate,
                thermalLevel: ThermalLevel(ProcessInfo.processInfo.thermalState)
            )
            do {
                try camera.lockForConfiguration()
                defer { camera.unlockForConfiguration() }
                let duration = CMTimeMake(value: 1, timescale: Int32(targetFPS))
                camera.activeVideoMinFrameDuration = duration
                camera.activeVideoMaxFrameDuration = duration
            } catch {
                Log.camera.error("thermal frame rate adjustment failed: \(error.localizedDescription)")
            }
        }
    }

    func stopThermalMonitoring() {
        if let observer = thermalObserver {
            NotificationCenter.default.removeObserver(observer)
            thermalObserver = nil
        }
    }

    // MARK: - Runtime errors

    /// Apple recommends restarting the session after the media services were reset.
    private func startRuntimeErrorObservation() {
        guard runtimeErrorObserver == nil else { return }
        runtimeErrorObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionRuntimeError,
            object: captureSession,
            queue: nil
        ) { [weak self] notification in
            guard let self,
                  let avError = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError else { return }
            Log.camera.error("capture session runtime error: \(avError.localizedDescription)")
            guard avError.code == .mediaServicesWereReset else { return }
            self.sessionQueue.async {
                if !self.captureSession.isRunning {
                    self.captureSession.startRunning()
                }
            }
        }
    }

    deinit {
        stopThermalMonitoring()
        if let observer = runtimeErrorObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

private extension ThermalLevel {
    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .nominal
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate & AVCaptureAudioDataOutputSampleBufferDelegate

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate,
                          AVCaptureAudioDataOutputSampleBufferDelegate {

    // Delegate callbacks arrive on `bufferQueue`.
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
}
