import Foundation
import Photos
import AVFoundation
import CoreLocation
import Combine
import DashCamCore

/// Merges buffered segments into one clip and saves it to the Photos library.
///
/// The merged file is only a temporary export: it is written to `protectedDirectory`,
/// handed to Photos, and then deleted.
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

    private enum SaveError: Error {
        case mergeFailed
        case photosAccessDenied
        case photosSaveFailed
    }

    init() {
        ensureDirectory()
        ioQueue.async { [weak self] in
            self?.cleanProtectedDirectory()
        }
    }

    /// Merges the segment files into one .mp4 (a single segment is saved as is) and saves it
    /// to Photos with the clip's start date and, when known, a location.
    /// `completion` is called on the main queue with success and the number of segments saved.
    func mergeSegmentsAndSaveToPhotos(
        segmentURLs: [URL],
        metadata: ClipMetadata,
        location: CLLocation?,
        completion: @escaping (Bool, Int) -> Void
    ) {
        guard !segmentURLs.isEmpty else {
            DispatchQueue.main.async { completion(false, 0) }
            return
        }

        DispatchQueue.main.async { self.isSaving = true }

        Task { [self] in
            var temporaryFile: URL?
            var failure: SaveError?

            do {
                let fileToSave: URL
                if segmentURLs.count == 1 {
                    fileToSave = segmentURLs[0]
                } else {
                    let merged = try await mergeFiles(segmentURLs, outputName: metadata.filename())
                    temporaryFile = merged
                    fileToSave = merged
                }
                try await saveFileToPhotos(fileToSave, creationDate: metadata.startDate, location: location)
            } catch let error as SaveError {
                failure = error
            } catch {
                Log.storage.error("saving to Photos failed: \(error.localizedDescription)")
                failure = .mergeFailed
            }

            if let temporaryFile {
                ioQueue.async { [fileManager] in try? fileManager.removeItem(at: temporaryFile) }
            }

            await MainActor.run {
                isSaving = false
                switch failure {
                case nil:
                    protectedCount += 1
                    lastSaveError = nil
                case .mergeFailed:
                    lastSaveError = NSLocalizedString("error.mergeFailed", comment: "")
                case .photosAccessDenied:
                    lastSaveError = NSLocalizedString("error.photosAccessDenied", comment: "")
                case .photosSaveFailed:
                    lastSaveError = NSLocalizedString("error.photosSaveFailed", comment: "")
                }
                completion(failure == nil, failure == nil ? segmentURLs.count : 0)
            }
        }
    }

    // MARK: - Private: Merge

    private func mergeFiles(_ urls: [URL], outputName: String) async throws -> URL {
        let composition = AVMutableComposition()

        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw SaveError.mergeFailed
        }

        let audioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )

        var insertTime = CMTime.zero
        var insertedAny = false

        for url in urls {
            let asset = AVURLAsset(url: url)

            // A segment that cannot be read (for example one cut short by a crash) is skipped.
            guard let assetVideoTrack = (try? await asset.loadTracks(withMediaType: .video))?.first else {
                Log.storage.warning("skipping unreadable segment \(url.lastPathComponent)")
                continue
            }
            let duration = try await asset.load(.duration)

            try videoTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: assetVideoTrack,
                at: insertTime
            )

            // Audio is optional: some segments might not have it.
            if let audioTrack,
               let assetAudioTrack = (try? await asset.loadTracks(withMediaType: .audio))?.first {
                try? audioTrack.insertTimeRange(
                    CMTimeRange(start: .zero, duration: duration),
                    of: assetAudioTrack,
                    at: insertTime
                )
            }

            // Apply the video transform from the first segment
            if !insertedAny {
                videoTrack.preferredTransform = try await assetVideoTrack.load(.preferredTransform)
            }

            insertedAny = true
            insertTime = CMTimeAdd(insertTime, duration)
        }

        guard insertedAny else { throw SaveError.mergeFailed }

        // Export merged composition
        let outputURL = Self.protectedDirectory.appendingPathComponent(outputName)
        try? fileManager.removeItem(at: outputURL)

        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            throw SaveError.mergeFailed
        }

        do {
            if #available(iOS 18.0, *) {
                try await exporter.export(to: outputURL, as: .mp4)
            } else {
                exporter.outputURL = outputURL
                exporter.outputFileType = .mp4
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    exporter.exportAsynchronously { continuation.resume() }
                }
                if exporter.status != .completed {
                    throw exporter.error ?? SaveError.mergeFailed
                }
            }
        } catch {
            // Do not leave a partial export behind.
            try? fileManager.removeItem(at: outputURL)
            throw error
        }
        return outputURL
    }

    // MARK: - Private: Save to Photos

    private func saveFileToPhotos(_ fileURL: URL, creationDate: Date, location: CLLocation?) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw SaveError.photosAccessDenied
        }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
                request?.creationDate = creationDate
                request?.location = location
            }
        } catch {
            Log.storage.error("Photos rejected the clip: \(error.localizedDescription)")
            throw SaveError.photosSaveFailed
        }
    }

    // MARK: - Private: Cleanup

    private func ensureDirectory() {
        try? fileManager.createDirectory(
            at: Self.protectedDirectory,
            withIntermediateDirectories: true
        )
    }

    /// Remove leftover exports from previous sessions.
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
