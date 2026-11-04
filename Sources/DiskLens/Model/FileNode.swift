import Foundation

/// A node in the scanned file tree. Built once on a background thread, then
/// only read or pruned (after a trash) on the main thread.
final class FileNode: Identifiable, Hashable {
    enum Kind {
        case directory
        case file
        case symlink
        /// A synthetic node that stands in for many small items, to keep the tree compact.
        case aggregate
    }

    let name: String
    let kind: Kind
    var size: Int64
    var itemCount: Int
    var children: [FileNode] = []
    weak var parent: FileNode?
    /// Absolute path; only set on the root node.
    var rootPath: String?
    var isAccessible = true

    init(name: String, kind: Kind, size: Int64 = 0, itemCount: Int = 1) {
        self.name = name
        self.kind = kind
        self.size = size
        self.itemCount = itemCount
    }

    var isDirectory: Bool { kind == .directory }

    var path: String {
        if let rootPath { return rootPath }
        guard let parent else { return name }
        let base = parent.path
        return base.hasSuffix("/") ? base + name : base + "/" + name
    }

    var url: URL { URL(fileURLWithPath: path) }

    /// Root first, self last.
    var ancestors: [FileNode] {
        var chain: [FileNode] = []
        var node: FileNode? = self
        while let n = node {
            chain.append(n)
            node = n.parent
        }
        return chain.reversed()
    }

    /// Removes a child and subtracts its size from every ancestor.
    func removeChild(_ child: FileNode) {
        children.removeAll { $0 === child }
        var node: FileNode? = self
        while let n = node {
            n.size -= child.size
            n.itemCount -= child.itemCount
            node = n.parent
        }
    }

    static func == (lhs: FileNode, rhs: FileNode) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}
