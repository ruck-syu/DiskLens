import Foundation
import Observation

struct LargeFile: Identifiable, Hashable {
    let path: String
    let name: String
    let folder: String
    let size: Int64
    let modified: Date
    let accessed: Date
    var id: String { path }
}

@MainActor
@Observable
final class LargeFilesModel {
    static let thresholds: [Int64] = [50, 100, 250, 500, 1000].map { $0 * 1_000_000 }

    var rootPath = NSHomeDirectory()
    var threshold: Int64 = 100_000_000
    var files: [LargeFile] = []
    var isScanning = false
    var hasScanned = false
    var scannedCount = 0
    var sortOrder = [KeyPathComparator(\LargeFile.size, order: .reverse)]

    @ObservationIgnored private var control: ScanControl?

    func scan() {
        control?.cancel()
        let control = ScanControl()
        self.control = control
        isScanning = true
        files = []
        scannedCount = 0
        let root = rootPath
        let minSize = threshold

        Task { [weak self] in
            while let self, self.isScanning, self.control === control {
                self.scannedCount = control.snapshot().files
                try? await Task.sleep(for: .milliseconds(150))
            }
        }

        Task {
            let records = await Task.detached(priority: .userInitiated) {
                DiskScanner(rootPath: root, control: control).findLargeFiles(minSize: minSize)
            }.value
            guard self.control === control, !control.isCancelled else { return }
            files = records.map {
                LargeFile(
                    path: $0.path,
                    name: ($0.path as NSString).lastPathComponent,
                    folder: (($0.path as NSString).deletingLastPathComponent).abbreviatingHome,
                    size: $0.size,
                    modified: $0.modified,
                    accessed: $0.accessed
                )
            }
            files.sort(using: sortOrder)
            scannedCount = control.snapshot().files
            isScanning = false
            hasScanned = true
        }
    }

    func cancel() {
        control?.cancel()
        control = nil
        isScanning = false
    }

    func trash(ids: Set<String>) async -> TrashResult {
        let paths = Array(ids)
        let result = await Task.detached { Trash.move(paths: paths) }.value
        let trashed = Set(result.trashed)
        files.removeAll { trashed.contains($0.path) }
        return result
    }
}
