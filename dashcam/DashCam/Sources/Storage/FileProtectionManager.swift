import Foundation
import Photos
import AVFoundation
import Combine

final class FileProtectionManager: ObservableObject {
    static var protectedDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("dashcam/protected")
    }

    @Published private(set) var protectedCount: Int = 0
    @Published private(set) var lastSaveError: String?
    @Published private(set) var isSaving = false

    private let fileManager = FileManager.default

    /// Background queue for file cleanup I/O
    private let ioQueue = DispatchQueue(label: "com.dashcam.protection.io", qos: .utility)

    init() {
        ensureDirectory()
        ioQueue.async { [weak self] in
            self?.cleanProtectedDirectory()
        }
    }

    /// Merge multiple segment files into one .mp4, save to Photos.
    /// Completion is called on main queue with success/failure.
    func mergeSegmentsAndSaveToPhotos(
        segmentURLs: [URL],
        label: String,
        completion: @escaping (Bool, Int) -> Void
    ) {
        guard !segmentURLs.isEmpty else {
            DispatchQueue.main.async { completion(false, 0) }
            return
        }

        DispatchQueue.main.async { self.isSaving = true }

        // If only one segment, save directly without merging
        if segmentURLs.count == 1 {
            saveFileToPhotos(segmentURLs[0]) { [weak self] success in
                DispatchQueue.main.async {
                    self?.isSaving = false
                    if success {
                        self?.protectedCount += 1
                    }
                    completion(success, 1)
                }
            }
            return
        }

        // Multiple segments: merge with AVMutableComposition (on background)
        ioQueue.async { [weak self] in
            self?.mergeFiles(segmentURLs) { [weak self] mergedURL in
                guard let self, let mergedURL else {
                    DispatchQueue.main.async {
                        self?.isSaving = false
                        self?.lastSaveError = NSLocalizedString("error.mergeFailed", comment: "")
                        completion(false, 0)
                    }
                    return
                }

                self.saveFileToPhotos(mergedURL) { [weak self] success in
                    // Clean up merged temp file on background
                    self?.ioQueue.async { try? FileManager.default.removeItem(at: mergedURL) }

                    DispatchQueue.main.async {
                        self?.isSaving = false
                        if success {
                            self?.protectedCount += 1
                        } else {
                            self?.lastSaveError = NSLocalizedString("error.photosSaveFailed", comment: "")
                        }
                        completion(success, segmentURLs.count)
                    }
                }
            }
        }
    }

    // MARK: - Private: Merge

    private func mergeFiles(_ urls: [URL], completion: @escaping (URL?) -> Void) {
        let composition = AVMutableComposition()

        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            completion(nil)
            return
        }

        let audioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )

        var insertTime = CMTime.zero

        for url in urls {
            let asset = AVURLAsset(url: url)

            // Video
            if let assetVideoTrack = asset.tracks(withMediaType: .video).first {
                let duration = asset.duration
                do {
                    try videoTrack.insertTimeRange(
                        CMTimeRange(start: .zero, duration: duration),
                        of: assetVideoTrack,
                        at: insertTime
                    )
                } catch {
                    print("Failed to insert video track from \(url.lastPathComponent): \(error)")
                    completion(nil)
                    return
                }

                // Audio (optional — some segments might not have audio)
                if let assetAudioTrack = asset.tracks(withMediaType: .audio).first,
                   let audioTrack {
                    try? audioTrack.insertTimeRange(
                        CMTimeRange(start: .zero, duration: duration),
                        of: assetAudioTrack,
                        at: insertTime
                    )
                }

                // Apply the video transform from the first segment
                if insertTime == .zero {
                    videoTrack.preferredTransform = assetVideoTrack.preferredTransform
                }

                insertTime = CMTimeAdd(insertTime, duration)
            }
        }

        // Export merged composition
        let outputURL = Self.protectedDirectory
            .appendingPathComponent("merged_\(UUID().uuidString.prefix(8)).mp4")

        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            completion(nil)
            return
        }

        exporter.outputURL = outputURL
        exporter.outputFileType = .mp4

        exporter.exportAsynchronously {
            switch exporter.status {
            case .completed:
                completion(outputURL)
            default:
                if let error = exporter.error {
                    print("Export failed: \(error)")
                }
                completion(nil)
            }
        }
    }

    // MARK: - Private: Save to Photos

    private func saveFileToPhotos(_ fileURL: URL, completion: @escaping (Bool) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async {
                    self?.lastSaveError = NSLocalizedString("error.photosAccessDenied", comment: "")
                }
                completion(false)
                return
            }

            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
            } completionHandler: { success, error in
                if !success, let error {
                    DispatchQueue.main.async {
                        self?.lastSaveError = "保存失败: \(error.localizedDescription)"
                    }
                    print("Failed to save to Photos: \(error)")
                }
                completion(success)
            }
        }
    }

    // MARK: - Private: Cleanup

    private func ensureDirectory() {
        try? fileManager.createDirectory(
            at: Self.protectedDirectory,
            withIntermediateDirectories: true
        )
    }

    /// Remove leftover files from previous sessions.
    private func cleanProtectedDirectory() {
        guard let files = try? fileManager.contentsOfDirectory(
            at: Self.protectedDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        for file in files {
            try? fileManager.removeItem(at: file)
        }
    }
}
