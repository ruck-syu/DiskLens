import AppKit
import Observation
import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case overview, explorer, cleanup, largeFiles

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .explorer: "Explorer"
        case .cleanup: "Cleanup"
        case .largeFiles: "Large Files"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "internaldrive"
        case .explorer: "square.grid.3x3.square"
        case .cleanup: "sparkles"
        case .largeFiles: "doc.badge.ellipsis"
        }
    }
}

@MainActor
@Observable
final class AppStore {
    var selection: SidebarItem? = .overview
    let explorer = ExplorerModel()
    let cleanup = CleanupModel()
    let largeFiles = LargeFilesModel()
    let updater = Updater()
    var volumes: [VolumeInfo] = VolumeInfo.all()

    func refreshVolumes() { volumes = VolumeInfo.all() }

    func scanInExplorer(_ path: String) {
        selection = .explorer
        explorer.scan(path: path)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (e.g. `swift run`).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct DiskLensApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = AppStore()

    var body: some Scene {
        WindowGroup("DiskLens") {
            ContentView()
                .environment(store)
                .frame(minWidth: 980, minHeight: 620)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { store.updater.checkFromMenu() }
            }
            CommandGroup(after: .newItem) {
                Button("Scan Home Folder") { store.scanInExplorer(NSHomeDirectory()) }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                Button("Scan Folder…") {
                    if let path = Finder.chooseFolder() { store.scanInExplorer(path) }
                }
                .keyboardShortcut("o")
                Button("Rescan") { store.explorer.rescan() }
                    .keyboardShortcut("r")
                    .disabled(store.explorer.root == nil)
            }
        }
    }
}

struct ContentView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        @Bindable var updater = store.updater
        NavigationSplitView {
            List(selection: $store.selection) {
                Section("Storage") {
                    ForEach(SidebarItem.allCases) { item in
                        Label(item.title, systemImage: item.symbol).tag(item)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    SidebarUpdateBadge(updater: store.updater)
                    SidebarDiskMeter()
                }
            }
        } detail: {
            switch store.selection ?? .overview {
            case .overview: OverviewView()
            case .explorer: ExplorerView()
            case .cleanup: CleanupView()
            case .largeFiles: LargeFilesView()
            }
        }
        .sheet(isPresented: $updater.isSheetPresented) {
            UpdateSheet(updater: store.updater)
        }
        .task { await store.updater.autoCheckOnLaunch() }
    }
}

struct SidebarDiskMeter: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        if let volume = store.volumes.first(where: \.isRoot) ?? store.volumes.first {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "internaldrive")
                    Text(volume.name).font(.callout.weight(.medium)).lineLimit(1)
                }
                UsageBar(fraction: volume.usedFraction)
                    .frame(height: 6)
                Text("\(volume.availableImportant.formattedBytes) available of \(volume.total.formattedBytes)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
        }
    }
}

struct UsageBar: View {
    var fraction: Double
    var tint: Color? = nil

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(tint ?? (fraction > 0.9 ? .red : fraction > 0.75 ? .orange : .accentColor))
                    .frame(width: max(2, geo.size.width * min(1, max(0, fraction))))
            }
        }
    }
}
