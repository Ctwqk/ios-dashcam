import Foundation
import Combine
import DashCamCore

/// What the disk looked like at one point in time.
struct StorageSample {
    let freeBytes: Int64
    let bufferBytes: Int64
    let protectedBytes: Int64
}

final class StorageManager: ObservableObject {
    @Published private(set) var availableStorageGB: Double = 0
    @Published private(set) var bufferSizeMB: Double = 0
    @Published private(set) var protectedSizeMB: Double = 0
    @Published var isStorageLow = false

    /// Called on the main thread after every refresh.
    var onSample: ((StorageSample) -> Void)?

    private let policy: StoragePolicy
    private var timer: Timer?
    private let fileManager = FileManager.default

    /// Background queue for directory scanning I/O
    private let ioQueue = DispatchQueue(label: "com.dashcam.storage.io", qos: .utility)

    init(policy: StoragePolicy = StoragePolicy()) {
        self.policy = policy
    }

    func startMonitoring() {
        stopMonitoring()
        updateStorageInfo()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.updateStorageInfo()
        }
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    func updateStorageInfo() {
        ioQueue.async { [weak self] in
            guard let self else { return }

            var freeBytes: Int64 = 0
            if let attrs = try? self.fileManager.attributesOfFileSystem(forPath: NSHomeDirectory()),
               let freeSpace = attrs[.systemFreeSize] as? Int64 {
                freeBytes = freeSpace
            }

            let sample = StorageSample(
                freeBytes: freeBytes,
                bufferBytes: self.directorySize(LoopBufferManager.segmentsDirectory),
                protectedBytes: self.directorySize(FileProtectionManager.protectedDirectory)
            )

            DispatchQueue.main.async {
                self.availableStorageGB = Double(sample.freeBytes) / Double(StoragePolicy.gibibyte)
                self.isStorageLow = self.policy.isLow(freeBytes: sample.freeBytes)
                self.bufferSizeMB = Double(sample.bufferBytes) / Double(StoragePolicy.mebibyte)
                self.protectedSizeMB = Double(sample.protectedBytes) / Double(StoragePolicy.mebibyte)
                self.onSample?(sample)
            }
        }
    }

    // MARK: - Private

    private func directorySize(_ url: URL) -> Int64 {
        guard let files = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        return files.reduce(Int64(0)) { total, fileURL in
            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return total + Int64(size)
        }
    }

    deinit {
        stopMonitoring()
    }
}
