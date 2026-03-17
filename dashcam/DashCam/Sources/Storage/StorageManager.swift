import Foundation
import Combine

final class StorageManager: ObservableObject {
    @Published private(set) var availableStorageGB: Double = 0
    @Published private(set) var bufferSizeMB: Double = 0
    @Published private(set) var protectedSizeMB: Double = 0
    @Published var isStorageLow = false

    private let lowStorageThresholdGB: Double = 1.0
    private var timer: Timer?
    private let fileManager = FileManager.default

    /// Background queue for directory scanning I/O
    private let ioQueue = DispatchQueue(label: "com.dashcam.storage.io", qos: .utility)

    func startMonitoring() {
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

            var freeGB: Double = 0
            if let attrs = try? self.fileManager.attributesOfFileSystem(
                forPath: NSHomeDirectory()
            ),
               let freeSpace = attrs[.systemFreeSize] as? Int64 {
                freeGB = Double(freeSpace) / 1_073_741_824
            }

            let bufMB = self.directorySize(LoopBufferManager.segmentsDirectory) / 1_048_576
            let protMB = self.directorySize(FileProtectionManager.protectedDirectory) / 1_048_576

            DispatchQueue.main.async {
                self.availableStorageGB = freeGB
                self.isStorageLow = freeGB < self.lowStorageThresholdGB
                self.bufferSizeMB = bufMB
                self.protectedSizeMB = protMB
            }
        }
    }

    // MARK: - Private

    private func directorySize(_ url: URL) -> Double {
        guard let files = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        return files.reduce(0) { total, fileURL in
            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return total + Double(size)
        }
    }

    deinit {
        stopMonitoring()
    }
}
