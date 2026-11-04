import Darwin
import Foundation

/// Thread-safe progress and cancellation shared between a scan and the UI.
final class ScanControl: @unchecked Sendable {
    struct Snapshot: Equatable {
        var files: Int
        var bytes: Int64
        var path: String
    }

    private let lock = NSLock()
    private var cancelled = false
    private var files = 0
    private var bytes: Int64 = 0
    private var currentPath = ""

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    func record(files n: Int, bytes b: Int64, path: String) {
        lock.lock()
        files += n
        bytes += b
        currentPath = path
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(files: files, bytes: bytes, path: currentPath)
    }
}

/// Remembers hard-linked files so they are only counted once.
private final class InodeSet: @unchecked Sendable {
    private struct Key: Hashable { let dev: Int32; let ino: UInt64 }
    private let lock = NSLock()
    private var seen = Set<Key>()

    /// Returns true the first time a (device, inode) pair is seen.
    func insert(dev: dev_t, ino: ino_t) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return seen.insert(Key(dev: Int32(dev), ino: UInt64(ino))).inserted
    }
}

struct LargeFileRecord: Sendable {
    let path: String
    let size: Int64
    let modified: Date
    let accessed: Date
}

/// Fast lstat-based scanner. Sizes are allocated bytes on disk (like `du`),
/// it never crosses into other volumes, and hard links are counted once.
struct DiskScanner {
    let rootPath: String
    let control: ScanControl
    var maxChildren = 250

    private let allowedDevices: Set<dev_t>
    private let excludedPaths: Set<String>
    private let inodes = InodeSet()

    init(rootPath: String, control: ScanControl) {
        let resolved = URL(fileURLWithPath: rootPath).resolvingSymlinksInPath().path
        self.rootPath = resolved
        self.control = control

        var devices = Set<dev_t>()
        var st = stat()
        if lstat(resolved, &st) == 0 { devices.insert(st.st_dev) }

        var excluded: Set<String> = []
        if resolved == "/" {
            // On APFS, "/" is the sealed system volume and user data lives on the Data
            // volume, which is firmlinked into /Users, /Applications, etc. Allow both
            // devices but skip the Data volume's own mount point to avoid double counting.
            if lstat("/System/Volumes/Data", &st) == 0 { devices.insert(st.st_dev) }
            excluded = ["/System/Volumes", "/Volumes", "/dev", "/net", "/home"]
        }
        self.allowedDevices = devices
        self.excludedPaths = excluded
    }

    static func join(_ dir: String, _ name: String) -> String {
        dir.hasSuffix("/") ? dir + name : dir + "/" + name
    }

    // MARK: Tree scan

    func scan() -> FileNode {
        let name = FileManager.default.displayName(atPath: rootPath)
        let node = scanDirectory(path: rootPath, name: name, depth: 0)
        node.rootPath = rootPath
        return node
    }

    private func scanDirectory(path: String, name: String, depth: Int) -> FileNode {
        let node = FileNode(name: name, kind: .directory, size: 0, itemCount: 0)
        guard !control.isCancelled else { return node }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            node.isAccessible = false
            return node
        }

        var files: [FileNode] = []
        var subdirs: [(path: String, name: String)] = []
        var localBytes: Int64 = 0

        for entry in names {
            let full = Self.join(path, entry)
            var st = stat()
            guard lstat(full, &st) == 0 else { continue }
            let type = st.st_mode & S_IFMT
            if type == S_IFDIR {
                guard allowedDevices.contains(st.st_dev), !excludedPaths.contains(full) else { continue }
                subdirs.append((full, entry))
            } else {
                var size = Int64(st.st_blocks) * 512
                if type == S_IFREG, st.st_nlink > 1, !inodes.insert(dev: st.st_dev, ino: st.st_ino) {
                    size = 0
                }
                files.append(FileNode(name: entry, kind: type == S_IFLNK ? .symlink : .file, size: size))
                localBytes += size
            }
        }
        control.record(files: files.count, bytes: localBytes, path: path)

        var dirNodes: [FileNode]
        if depth < 3 && subdirs.count > 1 {
            let lock = NSLock()
            var results = [FileNode?](repeating: nil, count: subdirs.count)
            DispatchQueue.concurrentPerform(iterations: subdirs.count) { i in
                let child = scanDirectory(path: subdirs[i].path, name: subdirs[i].name, depth: depth + 1)
                lock.lock(); results[i] = child; lock.unlock()
            }
            dirNodes = results.compactMap { $0 }
        } else {
            dirNodes = subdirs.map { scanDirectory(path: $0.path, name: $0.name, depth: depth + 1) }
        }

        var all = files + dirNodes
        all.sort { $0.size > $1.size }
        node.size = all.reduce(0) { $0 + $1.size }
        node.itemCount = files.count + dirNodes.reduce(0) { $0 + $1.itemCount }

        if all.count > maxChildren {
            let rest = all[maxChildren...]
            let aggregate = FileNode(
                name: "\(rest.count) smaller items",
                kind: .aggregate,
                size: rest.reduce(0) { $0 + $1.size },
                itemCount: rest.reduce(0) { $0 + $1.itemCount }
            )
            all = Array(all.prefix(maxChildren)) + [aggregate]
            all.sort { $0.size > $1.size }
        }
        for child in all { child.parent = node }
        node.children = all
        return node
    }

    // MARK: Totals

    /// Total allocated size of a file or folder.
    func totalSize(of path: String) -> Int64 {
        var st = stat()
        guard lstat(path, &st) == 0 else { return 0 }
        let type = st.st_mode & S_IFMT
        guard type == S_IFDIR else {
            if type == S_IFREG, st.st_nlink > 1, !inodes.insert(dev: st.st_dev, ino: st.st_ino) { return 0 }
            return Int64(st.st_blocks) * 512
        }
        guard !control.isCancelled,
              let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return 0 }
        var total: Int64 = 0
        for entry in names {
            total += totalSize(of: Self.join(path, entry))
        }
        return total
    }

    // MARK: Large files

    func findLargeFiles(minSize: Int64) -> [LargeFileRecord] {
        let lock = NSLock()
        var found: [LargeFileRecord] = []
        func visit(_ path: String, depth: Int) {
            guard !control.isCancelled,
                  let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return }
            var subdirs: [String] = []
            var count = 0
            for entry in names {
                let full = Self.join(path, entry)
                var st = stat()
                guard lstat(full, &st) == 0 else { continue }
                let type = st.st_mode & S_IFMT
                if type == S_IFDIR {
                    if allowedDevices.contains(st.st_dev), !excludedPaths.contains(full) { subdirs.append(full) }
                } else if type == S_IFREG {
                    count += 1
                    let size = Int64(st.st_blocks) * 512
                    if size >= minSize {
                        let record = LargeFileRecord(
                            path: full,
                            size: size,
                            modified: Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)),
                            accessed: Date(timeIntervalSince1970: TimeInterval(st.st_atimespec.tv_sec))
                        )
                        lock.lock(); found.append(record); lock.unlock()
                    }
                }
            }
            control.record(files: count, bytes: 0, path: path)
            if depth < 3 && subdirs.count > 1 {
                DispatchQueue.concurrentPerform(iterations: subdirs.count) { visit(subdirs[$0], depth: depth + 1) }
            } else {
                for dir in subdirs { visit(dir, depth: depth + 1) }
            }
        }
        visit(rootPath, depth: 0)
        return found.sorted { $0.size > $1.size }
    }
}
