import Foundation
import Observation

@MainActor
@Observable
final class ExplorerModel {
    var root: FileNode?
    var current: FileNode?
    var selection: Set<ObjectIdentifier> = []
    var hovered: FileNode?
    var isScanning = false
    var scanPath: String?
    var progress = ScanControl.Snapshot(files: 0, bytes: 0, path: "")
    var scanDuration: TimeInterval?
    /// Bumped whenever the tree is mutated in place so views re-layout.
    var version = 0

    @ObservationIgnored private var control: ScanControl?

    func scan(path: String) {
        control?.cancel()
        let control = ScanControl()
        self.control = control
        isScanning = true
        scanPath = path
        root = nil
        current = nil
        hovered = nil
        selection = []
        scanDuration = nil
        progress = .init(files: 0, bytes: 0, path: path)
        let start = Date()

        Task { [weak self] in
            while let self, self.isScanning, self.control === control {
                self.progress = control.snapshot()
                try? await Task.sleep(for: .milliseconds(120))
            }
        }

        Task {
            let node = await Task.detached(priority: .userInitiated) {
                DiskScanner(rootPath: path, control: control).scan()
            }.value
            guard self.control === control, !control.isCancelled else { return }
            self.root = node
            self.current = node
            self.progress = control.snapshot()
            self.scanDuration = Date().timeIntervalSince(start)
            self.isScanning = false
        }
    }

    func rescan() {
        if let path = root?.path ?? scanPath { scan(path: path) }
    }

    func cancel() {
        control?.cancel()
        control = nil
        isScanning = false
    }

    func drill(into node: FileNode) {
        guard node.isDirectory, !node.children.isEmpty else { return }
        current = node
        selection = []
        hovered = nil
    }

    func goUp() {
        if let parent = current?.parent { drill(into: parent) }
    }

    func nodes(for ids: Set<ObjectIdentifier>) -> [FileNode] {
        current?.children.filter { ids.contains($0.id) && $0.kind != .aggregate } ?? []
    }

    /// Moves nodes to the Trash and prunes them from the tree.
    func trash(_ nodes: [FileNode]) async -> TrashResult {
        let paths = nodes.map(\.path)
        let result = await Task.detached { Trash.move(paths: paths) }.value
        let trashed = Set(result.trashed)
        for node in nodes where trashed.contains(node.path) {
            node.parent?.removeChild(node)
        }
        selection.subtract(nodes.map(\.id))
        if let hovered, trashed.contains(hovered.path) { self.hovered = nil }
        version += 1
        return result
    }
}
