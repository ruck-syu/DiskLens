import SwiftUI

struct CleanupView: View {
    @Environment(AppStore.self) private var store
    @State private var showConfirm = false
    @State private var showEmptyTrashConfirm = false

    private var model: CleanupModel { store.cleanup }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            header
            if !Permissions.hasFullDiskAccess {
                FullDiskAccessBanner().padding(.horizontal, 16).padding(.bottom, 12)
            }
            List {
                ForEach(model.states) { state in
                    CategoryRow(state: state)
                }
                TrashRow(size: model.trashSize, accessible: model.trashAccessible) {
                    showEmptyTrashConfirm = true
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: false))
            Divider()
            footer
        }
        .navigationTitle("Cleanup")
        .toolbar {
            Button { model.refreshAll() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                .disabled(model.isLoading || model.isCleaning)
        }
        .onAppear { if !model.hasLoaded { model.refreshAll() } }
        .confirmationDialog(
            "Move \(model.selectedCount) items (\(model.selectedSize.formattedBytes)) to the Trash?",
            isPresented: $showConfirm
        ) {
            Button("Move to Trash", role: .destructive) { model.cleanSelected() }
        } message: {
            Text("Items stay in the Trash until you empty it, so nothing is lost yet. Apps will rebuild caches as needed, which can make them a little slower the first time.")
        }
        .confirmationDialog("Permanently erase the items in the Trash?", isPresented: $showEmptyTrashConfirm) {
            Button("Empty Trash", role: .destructive) {
                model.emptyTrash()
                store.refreshVolumes()
            }
        } message: {
            Text("This can't be undone. macOS may ask you to allow DiskLens to control Finder.")
        }
        .alert("Cleanup complete", isPresented: Binding(get: { model.lastSummary != nil }, set: { if !$0 { model.lastSummary = nil } }), presenting: model.lastSummary) { _ in
            Button("Empty Trash…") { showEmptyTrashConfirm = true }
            Button("Done", role: .cancel) { store.refreshVolumes() }
        } message: { summary in
            Text(summaryText(summary))
        }
        .alert("Couldn't empty the Trash", isPresented: Binding(get: { model.trashError != nil }, set: { if !$0 { model.trashError = nil } })) {
            Button("Open Trash") { Trash.openInFinder() }
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.trashError ?? "")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                if model.isLoading {
                    Text("Looking for reclaimable space…").font(.title2.weight(.semibold))
                } else {
                    Text("\(model.totalFound.formattedBytes) found").font(.title2.weight(.semibold))
                }
                Text("\(model.safeReclaimable.formattedBytes) is regenerated automatically and safe to remove. Items marked Review are left unselected.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isLoading { ProgressView().controlSize(.small) }
        }
        .padding(16)
    }

    private var footer: some View {
        HStack {
            if model.isCleaning {
                ProgressView().controlSize(.small)
                Text("Moving items to the Trash…")
            } else {
                Text("\(model.selectedCount) items selected")
                Text(model.selectedSize.formattedBytes).fontWeight(.semibold).monospacedDigit()
            }
            Spacer()
            Button("Move to Trash…") { showConfirm = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.selectedCount == 0 || model.isCleaning || model.isLoading)
        }
        .padding(12)
    }

    private func summaryText(_ s: CleanupSummary) -> String {
        var text = "Moved \(s.count) items (\(s.bytes.formattedBytes)) to the Trash. Empty the Trash to free the space."
        if !s.failures.isEmpty {
            let names = s.failures.prefix(5).map { ($0.path as NSString).lastPathComponent }.joined(separator: ", ")
            text += "\n\n\(s.failures.count) items couldn't be moved (in use or protected): \(names)\(s.failures.count > 5 ? "…" : "")"
        }
        return text
    }
}

struct CategoryRow: View {
    @Bindable var state: CategoryState

    var body: some View {
        DisclosureGroup(isExpanded: $state.isExpanded) {
            if state.entries.isEmpty && !state.isLoading {
                Text(state.deniedPaths.isEmpty ? "Nothing to clean here." : "macOS blocked access. Grant Full Disk Access to include this.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 34)
            }
            ForEach(state.entries.prefix(500)) { entry in
                EntryRow(entry: entry, isOn: state.binding(for: entry), showsDate: state.category.risk == .review)
            }
            if state.entries.count > 500 {
                Text("+ \(state.entries.count - 500) more smaller items")
                    .font(.caption).foregroundStyle(.secondary).padding(.leading, 34)
            }
        } label: {
            HStack(spacing: 12) {
                Button(action: state.toggleAll) {
                    Image(systemName: checkboxSymbol)
                        .font(.title3)
                        .foregroundStyle(state.selectionState == .none ? Color.secondary : Color.accentColor)
                }
                .buttonStyle(.plain)
                .disabled(state.entries.isEmpty)

                Image(systemName: state.category.symbol)
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(state.category.tint.gradient, in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(state.category.title).font(.headline)
                        RiskBadge(risk: state.category.risk)
                    }
                    Text(state.category.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                if state.isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(state.total.formattedBytes).font(.body.weight(.semibold).monospacedDigit())
                        if state.selectionState == .some {
                            Text("\(state.selectedSize.formattedBytes) selected")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var checkboxSymbol: String {
        switch state.selectionState {
        case .none: "square"
        case .some: "minus.square.fill"
        case .all: "checkmark.square.fill"
        }
    }
}

struct EntryRow: View {
    let entry: CleanupEntry
    @Binding var isOn: Bool
    let showsDate: Bool

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.checkbox)
            Image(nsImage: NSWorkspace.shared.icon(forFile: entry.path))
                .resizable()
                .frame(width: 16, height: 16)
            Text(entry.name).lineLimit(1).truncationMode(.middle)
            Spacer()
            if showsDate, let modified = entry.modified {
                Text(modified, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(entry.size.formattedBytes)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 70, alignment: .trailing)
            Button { Finder.reveal([entry.path]) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless)
                .help("Reveal in Finder")
        }
        .padding(.leading, 22)
    }
}

struct RiskBadge: View {
    let risk: CleanupRisk

    var body: some View {
        Text(risk == .safe ? "Safe" : "Review")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .foregroundStyle(risk == .safe ? Color.green : Color.orange)
            .background((risk == .safe ? Color.green : Color.orange).opacity(0.15), in: Capsule())
    }
}

struct TrashRow: View {
    let size: Int64?
    let accessible: Bool
    var onEmpty: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "square").font(.title3).hidden()
            Image(systemName: "trash")
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Color.red.gradient, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text("Trash").font(.headline)
                Text(accessible
                     ? "Items you've deleted still use space until the Trash is emptied."
                     : "Grant Full Disk Access to see how much space the Trash uses.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let size { Text(size.formattedBytes).font(.body.weight(.semibold).monospacedDigit()) }
            Button("Open") { Trash.openInFinder() }
            Button("Empty…", action: onEmpty)
                .disabled(accessible && (size ?? 0) == 0)
        }
        .padding(.vertical, 4)
        .padding(.leading, 20)
    }
}
