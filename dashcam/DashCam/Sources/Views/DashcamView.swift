import SwiftUI
import Photos
import DashCamCore

struct DashcamView: View {
    @StateObject private var viewModel = DashcamViewModel()
    @Environment(\.scenePhase) private var scenePhase
    // `-showSettings` opens the Settings sheet at launch; the CI screenshot job uses it.
    @State private var showSettings = ProcessInfo.processInfo.arguments.contains("-showSettings")

    var body: some View {
        ZStack {
            CameraPreviewView(session: viewModel.cameraManager.captureSession)
                .ignoresSafeArea()

            VStack {
                topOverlay
                Spacer()
                bottomOverlay
            }

            if let cameraError = viewModel.cameraError {
                cameraErrorCard(cameraError)
            }

            if viewModel.collisionDetected {
                collisionAlert
            }

            if viewModel.isStorageLow {
                storageWarning
            }

            if let reason = viewModel.interruptionReason {
                interruptionBanner(reason)
            }

            if let status = viewModel.saveStatusMessage {
                saveStatusBanner(status)
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .modifier(HidePersistentOverlaysModifier())
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            viewModel.refreshCameraAvailability()
            if viewModel.recordingState == .paused {
                viewModel.startRecording()
            }
        }
        .alert(NSLocalizedString("alert.stopRecording", comment: ""), isPresented: $viewModel.showSaveDialog) {
            Button(NSLocalizedString("alert.saveToPhotos", comment: ""), role: nil) {
                viewModel.saveAndStopRecording()
            }
            Button(NSLocalizedString("alert.discard", comment: ""), role: .destructive) {
                viewModel.discardAndStopRecording()
            }
            Button(NSLocalizedString("alert.continueRecording", comment: ""), role: .cancel) {}
        } message: {
            let mins = Int(viewModel.elapsedTime) / 60
            let secs = Int(viewModel.elapsedTime) % 60
            Text("alert.recordedDuration \(mins) \(secs)")
        }
        .onAppear {
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(config: $viewModel.config)
                .onDisappear {
                    viewModel.applyConfig(viewModel.config)
                }
        }
    }

    // MARK: - Top Overlay

    private var topOverlay: some View {
        HStack {
            HStack(spacing: 6) {
                Circle()
                    .fill(recordingIndicatorColor)
                    .frame(width: 12, height: 12)
                    .opacity(viewModel.recordingState == .recording ? 1 : 0.4)

                Text(recordingStatusText)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
            }

            Spacer()

            if viewModel.recordingState == .recording {
                Text(formatDuration(viewModel.elapsedTime))
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundColor(.white)
            }

            Spacer()

            if viewModel.recordingState == .idle {
                Button(action: { showSettings = true }) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.white.opacity(0.8))
                }
            }

            Text(Date(), style: .time)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.8))
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 8)
        .background(
            LinearGradient(
                colors: [.black.opacity(0.7), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    // MARK: - Bottom Overlay

    private var bottomOverlay: some View {
        VStack(spacing: 16) {
            HStack(spacing: 24) {
                VStack(spacing: 2) {
                    Text("\(Int(viewModel.currentSpeed))")
                        .font(.system(size: 32, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                    if viewModel.isLocationDenied {
                        Text("hud.gpsOff")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.yellow.opacity(0.8))
                    } else {
                        Text("km/h")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.6))
                    }
                }

                Spacer()

                VStack(spacing: 2) {
                    Text("\(viewModel.segmentCount)/\(viewModel.config.maxSegments)")
                        .font(.system(size: 16, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                    Text("\(viewModel.config.bufferMinutes)min")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                }

                if viewModel.protectedCount > 0 {
                    VStack(spacing: 2) {
                        Text("\(viewModel.protectedCount)")
                            .font(.system(size: 16, weight: .semibold, design: .monospaced))
                            .foregroundColor(.orange)
                        Text("saved")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.orange.opacity(0.6))
                    }
                }

                Spacer()

                VStack(spacing: 2) {
                    Text(String(format: "%.1f", viewModel.availableStorageGB))
                        .font(.system(size: 16, weight: .semibold, design: .monospaced))
                        .foregroundColor(viewModel.isStorageLow ? .red : .white)
                    Text("GB free")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                }
            }
            .padding(.horizontal, 24)

            Button(action: { viewModel.toggleRecording() }) {
                ZStack {
                    Circle()
                        .strokeBorder(.white.opacity(0.8), lineWidth: 3)
                        .frame(width: 72, height: 72)

                    if viewModel.recordingState == .recording {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(.red)
                            .frame(width: 28, height: 28)
                    } else {
                        Circle()
                            .fill(.red)
                            .frame(width: 58, height: 58)
                    }
                }
            }
            .disabled(viewModel.cameraError == .cameraUnavailable)
            .opacity(viewModel.cameraError == .cameraUnavailable ? 0.4 : 1)
            .padding(.bottom, 8)

            HStack {
                Text(String(format: "%.1fg", viewModel.currentGForce))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.4))
            }
        }
        .padding(.bottom, 20)
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(0.8)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    // MARK: - Alerts

    private var collisionAlert: some View {
        VStack {
            Spacer()
                .frame(height: 100)
            Text("hud.collisionDetected")
                .font(.system(size: 20, weight: .black, design: .monospaced))
                .foregroundColor(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(Color.red)
                .cornerRadius(8)
            Text("hud.savedToPhotos")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white.opacity(0.8))
                .padding(.top, 4)
            Spacer()
        }
        .transition(.opacity)
        .animation(.easeInOut, value: viewModel.collisionDetected)
    }

    /// Empty state shown when there is no usable camera (simulator, no permission).
    /// Compact and anchored below the top bar so it does not cover the HUD in landscape.
    private func cameraErrorCard(_ error: CameraError) -> some View {
        VStack {
            Spacer().frame(height: 56)
            HStack(spacing: 14) {
                Image(systemName: "video.slash.fill")
                    .font(.system(size: 28))
                VStack(alignment: .leading, spacing: 8) {
                    Text(error.message)
                        .font(.system(size: 14, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    if error.canOpenSettings {
                        Button("camera.openSettings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
            }
            .foregroundColor(.white)
            .padding(16)
            .frame(maxWidth: 460)
            .background(Color.black.opacity(0.75))
            .cornerRadius(12)
            Spacer()
        }
    }

    private var storageWarning: some View {
        VStack {
            HStack {
                Spacer()
                Text("hud.lowStorage")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(.black)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.yellow)
                    .cornerRadius(4)
                    .padding(.trailing, 16)
                    .padding(.top, 60)
            }
            Spacer()
        }
    }

    private func saveStatusBanner(_ message: String) -> some View {
        VStack {
            HStack {
                Text(message)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.green.opacity(0.85))
                    .cornerRadius(6)
            }
            .padding(.top, 60)
            Spacer()
        }
        .transition(.opacity)
        .animation(.easeInOut, value: viewModel.saveStatusMessage)
    }

    private func interruptionBanner(_ reason: String) -> some View {
        VStack {
            Spacer()
                .frame(height: 120)
            Text(reason)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.9))
                .cornerRadius(6)
            Spacer()
        }
    }

    // MARK: - Helpers

    private var recordingIndicatorColor: Color {
        switch viewModel.recordingState {
        case .recording: return .red
        case .paused: return .orange
        case .error: return .yellow
        case .idle: return .gray
        }
    }

    private var recordingStatusText: String {
        switch viewModel.recordingState {
        case .recording: return "REC"
        case .paused: return "PAUSED"
        case .error: return "ERROR"
        case .idle: return "READY"
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - iOS 16+ persistent overlays guard

private struct HidePersistentOverlaysModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.persistentSystemOverlays(.hidden)
        } else {
            content
        }
    }
}
