import Charts
import SwiftUI

struct OverviewView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if !Permissions.hasFullDiskAccess {
                    FullDiskAccessBanner()
                }

                ForEach(store.volumes) { volume in
                    VolumeCard(volume: volume)
                }

                Text("Quick Actions").font(.title3.weight(.semibold))
                HStack(alignment: .top, spacing: 16) {
                    ActionCard(
                        symbol: "square.grid.3x3.square", tint: .blue,
                        title: "Visualize Home",
                        detail: "See which folders take the most space as a treemap.",
                        button: "Scan Home Folder"
                    ) { store.scanInExplorer(NSHomeDirectory()) }

                    ActionCard(
                        symbol: "sparkles", tint: .purple,
                        title: "Clean Up",
                        detail: store.cleanup.hasLoaded && !store.cleanup.isLoading
                            ? "\(store.cleanup.safeReclaimable.formattedBytes) of caches and build data can be safely removed."
                            : "Find caches, logs and developer junk you can safely remove.",
                        button: "Review Cleanup"
                    ) { store.selection = .cleanup }

                    ActionCard(
                        symbol: "doc.badge.ellipsis", tint: .orange,
                        title: "Large Files",
                        detail: "Find big files you may have forgotten about.",
                        button: "Find Large Files"
                    ) {
                        store.selection = .largeFiles
                        if !store.largeFiles.hasScanned { store.largeFiles.scan() }
                    }
                }

                if let root = store.explorer.root, !root.children.isEmpty {
                    TopFoldersChart(root: root, version: store.explorer.version)
                }
            }
            .padding(24)
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Overview")
        .toolbar {
            Button { store.refreshVolumes() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
        }
        .onAppear {
            store.refreshVolumes()
            if !store.cleanup.hasLoaded { store.cleanup.refreshAll() }
        }
    }
}

private struct Segment: Identifiable {
    let name: String
    let bytes: Int64
    let color: Color
    var id: String { name }
}

struct VolumeCard: View {
    let volume: VolumeInfo

    private var segments: [Segment] {
        [
            Segment(name: "Used", bytes: volume.used, color: .accentColor),
            Segment(name: "Purgeable", bytes: volume.purgeable, color: .accentColor.opacity(0.4)),
            Segment(name: "Free", bytes: volume.availableRaw, color: Color.secondary.opacity(0.18)),
        ]
    }

    var body: some View {
        HStack(spacing: 28) {
            Chart(segments) { segment in
                SectorMark(
                    angle: .value("Bytes", max(segment.bytes, 1)),
                    innerRadius: .ratio(0.68),
                    angularInset: 1.5
                )
                .cornerRadius(4)
                .foregroundStyle(segment.color)
            }
            .chartLegend(.hidden)
            .frame(width: 150, height: 150)
            .overlay {
                VStack(spacing: 0) {
                    Text(volume.usedFraction, format: .percent.precision(.fractionLength(0)))
                        .font(.title.weight(.bold))
                    Text("used").font(.caption).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: volume.isInternal ? "internaldrive.fill" : "externaldrive.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading) {
                        Text(volume.name).font(.title2.weight(.semibold))
                        Text("\(volume.total.formattedBytes) total").foregroundStyle(.secondary)
                    }
                }
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    ForEach(segments) { segment in
                        GridRow {
                            Circle().fill(segment.color).frame(width: 10, height: 10)
                            Text(segment.name)
                            Text(segment.bytes.formattedBytes).monospacedDigit().fontWeight(.medium)
                        }
                    }
                }
                Text("Purgeable space is held by macOS (iCloud files, snapshots, caches) and freed automatically when needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(20)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct ActionCard: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    let button: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol)
                .font(.title)
                .foregroundStyle(tint)
            Text(title).font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(button, action: action)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct TopFoldersChart: View {
    let root: FileNode
    let version: Int

    var body: some View {
        let top = Array(root.children.prefix(10))
        VStack(alignment: .leading, spacing: 12) {
            Text("Largest items in \(root.name)").font(.title3.weight(.semibold))
            Chart(top, id: \.id) { node in
                BarMark(
                    x: .value("Size", Double(node.size) / 1_000_000_000),
                    y: .value("Name", node.name)
                )
                .foregroundStyle(Color.accentColor.gradient)
                .annotation(position: .trailing) {
                    Text(node.size.formattedBytes).font(.caption).foregroundStyle(.secondary)
                }
            }
            .chartXAxisLabel("GB")
            .chartYScale(domain: top.map(\.name))
            .frame(height: CGFloat(top.count) * 30 + 30)
        }
        .padding(20)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct FullDiskAccessBanner: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Grant Full Disk Access for complete results").font(.headline)
                Text("Without it, macOS hides some folders (Mail, Safari, Trash, backups) and their sizes won't be counted. After granting it, quit and reopen DiskLens.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Open Settings") { Permissions.openFullDiskAccessSettings() }
        }
        .padding(14)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }
}
