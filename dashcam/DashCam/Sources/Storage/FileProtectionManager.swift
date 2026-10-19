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
    private let directory: URL

    /// Background queue for file cleanup I/O
    private let ioQueue = DispatchQueue(label: "com.dashcam.protection.io", qos: .utility)

    private enum SaveError: Error {
        case mergeFailed
        case photosAccessDenied
        case photosSaveFailed
    }

    init(directory: URL = FileProtectionManager.protectedDirectory) {
        self.directory = directory
        ensureDirectory()
        // Snapshot old exports before accepting new ones; delayed cleanup must never
        // enumerate and delete a file created by an export from this session.
        let leftovers = (try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        ioQueue.async {
            for file in leftovers { try? FileManager.default.removeItem(at: file) }
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
            let failure = await export(segmentURLs, metadata: metadata, location: location)

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

    /// Merges (if needed) and saves; returns `nil` on success. Temporary files are always removed.
    private func export(_ segmentURLs: [URL], metadata: ClipMetadata, location: CLLocation?) async -> SaveError? {
        var temporaryFile: URL?
        defer {
            if let temporaryFile {
                ioQueue.async { try? FileManager.default.removeItem(at: temporaryFile) }
            }
        }

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
            return nil
        } catch let error as SaveError {
            return error
        } catch {
            Log.storage.error("export failed: \(error.localizedDescription)")
            return .mergeFailed
        }
    }

    // MARK: - Private: Merge

    func mergeFiles(_ urls: [URL], outputName: String) async throws -> URL {
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

            // Never report a partial clip as a successful save: the caller would then
            // delete the entire snapshot, including footage omitted from the export.
            guard let assetVideoTrack = try await asset.loadTracks(withMediaType: .video).first else {
                throw SaveError.mergeFailed
            }
            let duration = try await asset.load(.duration)

            try videoTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: assetVideoTrack,
                at: insertTime
            )

            // Audio is optional: some segments might not have it.
            if let audioTrack,
               let assetAudioTrack = try await asset.loadTracks(withMediaType: .audio).first {
                try audioTrack.insertTimeRange(
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
        let outputURL = directory.appendingPathComponent(outputName)
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
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .video, fileURL: fileURL, options: nil)
                request.creationDate = creationDate
                request.location = location
            }
        } catch {
            Log.storage.error("Photos rejected the clip: \(error.localizedDescription)")
            throw SaveError.photosSaveFailed
        }
    }

    // MARK: - Private: Cleanup

    private func ensureDirectory() {
        try? fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

}
