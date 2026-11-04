import Foundation
import Observation
import SwiftUI

enum CleanupRisk: Sendable {
    /// Regenerated automatically by apps and tools.
    case safe
    /// May contain things the user wants to keep; nothing is preselected.
    case review
}

enum CleanupMode: Sendable {
    /// Each item inside the folder is a separate entry.
    case contents
    /// The folder itself is one entry.
    case wholeItem
}

struct CleanupCategory: Identifiable, Sendable {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    let tint: Color
    let paths: [String]
    let mode: CleanupMode
    let risk: CleanupRisk

    var expandedPaths: [String] { paths.map { ($0 as NSString).expandingTildeInPath } }

    static let all: [CleanupCategory] = [
        .init(id: "caches", title: "User Caches",
              detail: "Temporary data apps keep to load faster. Apps rebuild it as needed.",
              symbol: "archivebox", tint: .blue,
              paths: ["~/Library/Caches"], mode: .contents, risk: .safe),
        .init(id: "logs", title: "Logs",
              detail: "Diagnostic logs written by apps and the system.",
              symbol: "doc.text", tint: .gray,
              paths: ["~/Library/Logs"], mode: .contents, risk: .safe),
        .init(id: "deriveddata", title: "Xcode Derived Data",
              detail: "Build products and indexes. Xcode recreates them on the next build.",
              symbol: "hammer", tint: .indigo,
              paths: ["~/Library/Developer/Xcode/DerivedData"], mode: .contents, risk: .safe),
        .init(id: "devicesupport", title: "Xcode Device Support",
              detail: "Debug symbols for devices you've connected. Re-downloaded when a device is plugged in.",
              symbol: "iphone", tint: .indigo,
              paths: ["~/Library/Developer/Xcode/iOS DeviceSupport",
                      "~/Library/Developer/Xcode/watchOS DeviceSupport",
                      "~/Library/Developer/Xcode/tvOS DeviceSupport",
                      "~/Library/Developer/Xcode/visionOS DeviceSupport"],
              mode: .contents, risk: .safe),
        .init(id: "simcaches", title: "Simulator Caches",
              detail: "Dyld and runtime caches for the iOS Simulator.",
              symbol: "ipad.and.iphone", tint: .indigo,
              paths: ["~/Library/Developer/CoreSimulator/Caches"], mode: .contents, risk: .safe),
        .init(id: "pkgcaches", title: "Package Manager Caches",
              detail: "Download caches for npm, pnpm, Bun, Gradle, Cargo and Go modules.",
              symbol: "shippingbox", tint: .orange,
              paths: ["~/.npm/_cacache", "~/Library/pnpm/store", "~/.bun/install/cache",
                      "~/.gradle/caches", "~/.cargo/registry/cache", "~/go/pkg/mod/cache/download"],
              mode: .wholeItem, risk: .safe),
        .init(id: "archives", title: "Xcode Archives",
              detail: "App builds you archived for distribution. Keep the ones you may need to symbolicate crashes.",
              symbol: "archivebox.fill", tint: .purple,
              paths: ["~/Library/Developer/Xcode/Archives"], mode: .contents, risk: .review),
        .init(id: "backups", title: "iPhone & iPad Backups",
              detail: "Local device backups made by Finder.",
              symbol: "externaldrive.badge.timemachine", tint: .teal,
              paths: ["~/Library/Application Support/MobileSync/Backup"], mode: .contents, risk: .review),
        .init(id: "downloads", title: "Downloads",
              detail: "Everything in your Downloads folder, oldest-first review recommended.",
              symbol: "arrow.down.circle", tint: .green,
              paths: ["~/Downloads"], mode: .contents, risk: .review),
    ]
}

struct CleanupEntry: Identifiable, Hashable, Sendable {
    let path: String
    let name: String
    let size: Int64
    let modified: Date?
    var id: String { path }
}

@MainActor
@Observable
final class CategoryState: Identifiable {
    enum Selection { case none, some, all }

    let category: CleanupCategory
    var entries: [CleanupEntry] = []
    var selected: Set<String> = []
    var deniedPaths: [String] = []
    var isLoading = false
    var hasLoaded = false
    var isExpanded = false

    nonisolated var id: String { category.id }

    init(category: CleanupCategory) { self.category = category }

    var total: Int64 { entries.reduce(0) { $0 + $1.size } }
    var selectedEntries: [CleanupEntry] { entries.filter { selected.contains($0.path) } }
    var selectedSize: Int64 { selectedEntries.reduce(0) { $0 + $1.size } }

    var selectionState: Selection {
        if selected.isEmpty || entries.isEmpty { return .none }
        return selected.count >= entries.count ? .all : .some
    }

    func toggleAll() {
        selected = selectionState == .all ? [] : Set(entries.map(\.path))
    }

    func binding(for entry: CleanupEntry) -> Binding<Bool> {
        Binding(
            get: { self.selected.contains(entry.path) },
            set: { isOn in
                if isOn { self.selected.insert(entry.path) } else { self.selected.remove(entry.path) }
            }
        )
    }
}

struct CleanupSummary: Identifiable {
    let id = UUID()
    let count: Int
    let bytes: Int64
    let failures: [TrashFailure]
}

@MainActor
@Observable
final class CleanupModel {
    let states: [CategoryState]
    var trashSize: Int64?
    var trashAccessible = true
    var isCleaning = false
    var hasLoaded = false
    var lastSummary: CleanupSummary?
    var trashError: String?

    init() {
        states = CleanupCategory.all.map { CategoryState(category: $0) }
    }

    var isLoading: Bool { states.contains { $0.isLoading } }
    var totalFound: Int64 { states.reduce(0) { $0 + $1.total } }
    var safeReclaimable: Int64 {
        states.filter { $0.category.risk == .safe }.reduce(0) { $0 + $1.total }
    }
    var selectedCount: Int { states.reduce(0) { $0 + $1.selected.count } }
    var selectedSize: Int64 { states.reduce(0) { $0 + $1.selectedSize } }

    func refreshAll() {
        hasLoaded = true
        for state in states { refresh(state) }
        refreshTrash()
    }

    func refresh(_ state: CategoryState) {
        state.isLoading = true
        let category = state.category
        Task {
            let (entries, denied) = await Task.detached(priority: .userInitiated) {
                Self.loadEntries(for: category)
            }.value
            state.entries = entries
            state.deniedPaths = denied
            state.selected = category.risk == .safe ? Set(entries.map(\.path)) : []
            state.isLoading = false
            state.hasLoaded = true
        }
    }

    func refreshTrash() {
        Task {
            let (size, accessible) = await Task.detached {
                let accessible = (try? FileManager.default.contentsOfDirectory(atPath: Trash.path)) != nil
                let size = accessible ? DiskScanner(rootPath: Trash.path, control: ScanControl()).totalSize(of: Trash.path) : 0
                return (size, accessible)
            }.value
            trashSize = accessible ? size : nil
            trashAccessible = accessible
        }
    }

    func cleanSelected() {
        let entries = states.flatMap(\.selectedEntries)
        guard !entries.isEmpty else { return }
        isCleaning = true
        let paths = entries.map(\.path)
        Task {
            let result = await Task.detached { Trash.move(paths: paths) }.value
            let trashed = Set(result.trashed)
            let bytes = entries.filter { trashed.contains($0.path) }.reduce(0) { $0 + $1.size }
            lastSummary = CleanupSummary(count: result.trashed.count, bytes: bytes, failures: result.failures)
            isCleaning = false
            refreshAll()
        }
    }

    func emptyTrash() {
        trashError = Trash.empty()
        refreshTrash()
    }

    nonisolated static func loadEntries(for category: CleanupCategory) -> ([CleanupEntry], [String]) {
        let fm = FileManager.default
        let scanner = DiskScanner(rootPath: NSHomeDirectory(), control: ScanControl())
        var candidates: [String] = []
        var denied: [String] = []

        for base in category.expandedPaths where fm.fileExists(atPath: base) {
            switch category.mode {
            case .wholeItem:
                candidates.append(base)
            case .contents:
                guard let names = try? fm.contentsOfDirectory(atPath: base) else {
                    denied.append(base)
                    continue
                }
                candidates += names
                    .filter { $0 != ".DS_Store" && $0 != ".localized" }
                    .map { DiskScanner.join(base, $0) }
            }
        }

        let lock = NSLock()
        var entries: [CleanupEntry] = []
        DispatchQueue.concurrentPerform(iterations: candidates.count) { i in
            let path = candidates[i]
            let size = scanner.totalSize(of: path)
            guard size > 0 else { return }
            let modified = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            var name = (path as NSString).lastPathComponent
            if category.mode == .wholeItem { name = path.abbreviatingHome }
            let entry = CleanupEntry(path: path, name: name, size: size, modified: modified)
            lock.lock(); entries.append(entry); lock.unlock()
        }
        return (entries.sorted { $0.size > $1.size }, denied)
    }
}
