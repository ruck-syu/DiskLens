import AppKit
import Foundation

extension Int64 {
    var formattedBytes: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}

extension String {
    /// Replaces the home directory prefix with "~".
    var abbreviatingHome: String { (self as NSString).abbreviatingWithTildeInPath }
}

// MARK: - Trash

struct TrashFailure: Sendable {
    let path: String
    let message: String
}

struct TrashResult: Sendable {
    var trashed: [String] = []
    var failures: [TrashFailure] = []
}

enum Trash {
    /// Moves items to the Trash (recoverable). Safe to call off the main thread.
    static func move(paths: [String]) -> TrashResult {
        var result = TrashResult()
        for path in paths {
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
                result.trashed.append(path)
            } catch {
                result.failures.append(TrashFailure(path: path, message: error.localizedDescription))
            }
        }
        return result
    }

    /// Asks Finder to empty the Trash. Returns an error message on failure.
    @MainActor
    static func empty() -> String? {
        var error: NSDictionary?
        let script = NSAppleScript(source: "tell application \"Finder\" to empty trash")
        script?.executeAndReturnError(&error)
        if let error {
            return (error[NSAppleScript.errorMessage] as? String) ?? "Finder could not empty the Trash."
        }
        return nil
    }

    static var path: String { NSHomeDirectory() + "/.Trash" }

    static func openInFinder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}

enum Finder {
    static func reveal(_ paths: [String]) {
        NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) })
    }

    static func open(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    static func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    @MainActor
    static func chooseFolder(message: String = "Choose a folder to scan") -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = message
        panel.prompt = "Scan"
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}

// MARK: - Permissions

enum Permissions {
    /// Reading ~/Library/Safari is gated by Full Disk Access, which makes it a cheap probe.
    static var hasFullDiskAccess: Bool {
        let probe = NSHomeDirectory() + "/Library/Safari"
        guard FileManager.default.fileExists(atPath: probe) else { return true }
        return (try? FileManager.default.contentsOfDirectory(atPath: probe)) != nil
    }

    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Volumes

struct VolumeInfo: Identifiable {
    let url: URL
    let name: String
    let total: Int64
    /// Free space including purgeable data (what the OS can make available).
    let availableImportant: Int64
    /// Strictly free space right now.
    let availableRaw: Int64
    let isRoot: Bool
    let isInternal: Bool

    var id: URL { url }
    var used: Int64 { max(0, total - availableImportant) }
    var purgeable: Int64 { max(0, availableImportant - availableRaw) }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    static func all() -> [VolumeInfo] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey, .volumeIsRootFileSystemKey,
            .volumeIsInternalKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)), let total = v.volumeTotalCapacity, total > 0 else { return nil }
            let raw = Int64(v.volumeAvailableCapacity ?? 0)
            let important = v.volumeAvailableCapacityForImportantUsage ?? raw
            return VolumeInfo(
                url: url,
                name: v.volumeName ?? url.lastPathComponent,
                total: Int64(total),
                availableImportant: max(important, raw),
                availableRaw: raw,
                isRoot: v.volumeIsRootFileSystem ?? false,
                isInternal: v.volumeIsInternal ?? false
            )
        }
        .sorted { ($0.isRoot ? 0 : 1, $0.name) < ($1.isRoot ? 0 : 1, $1.name) }
    }
}
