import SwiftUI

struct LargeFilesView: View {
    @Environment(AppStore.self) private var store
    @State private var selection: Set<String> = []
    @State private var search = ""
    @State private var showConfirm = false
    @State private var pending: Set<String> = []
    @State private var errorMessage: String?

    private var model: LargeFilesModel { store.largeFiles }

    private var visibleFiles: [LargeFile] {
        guard !search.isEmpty else { return model.files }
        return model.files.filter { $0.name.localizedCaseInsensitiveContains(search) || $0.folder.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            controls
            Divider()
            if model.isScanning {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Scanned \(model.scannedCount.formatted()) files…").monospacedDigit().foregroundStyle(.secondary)
                    Button("Cancel", action: model.cancel)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !model.hasScanned {
                ContentUnavailableView {
                    Label("Find large files", systemImage: "doc.badge.ellipsis")
                } description: {
                    Text("Locate big files in \(model.rootPath.abbreviatingHome) that you might not need anymore.")
                } actions: {
                    Button("Scan") { model.scan() }.buttonStyle(.borderedProminent).controlSize(.large)
                }
            } else {
                table
            }
            Divider()
            footer
        }
        .navigationTitle("Large Files")
        .searchable(text: $search, prompt: "Filter by name or folder")
        .confirmationDialog(confirmTitle, isPresented: $showConfirm) {
            Button("Move to Trash", role: .destructive) { performTrash() }
        } message: {
            Text("You can restore items from the Trash until it's emptied.")
        }
        .alert("Some files couldn't be moved", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var controls: some View {
        @Bindable var model = model
        return HStack(spacing: 12) {
            Text("Folder:")
            Button {
                if let path = Finder.chooseFolder(message: "Choose a folder to search for large files") {
                    model.rootPath = path
                    model.scan()
                }
            } label: {
                Label(model.rootPath.abbreviatingHome, systemImage: "folder")
            }
            Picker("Larger than", selection: $model.threshold) {
                ForEach(LargeFilesModel.thresholds, id: \.self) { Text($0.formattedBytes).tag($0) }
            }
            .fixedSize()
            Spacer()
            Button(model.hasScanned ? "Rescan" : "Scan") { model.scan() }
                .disabled(model.isScanning)
        }
        .padding(12)
    }

    private var table: some View {
        @Bindable var model = model
        return Table(visibleFiles, selection: $selection, sortOrder: $model.sortOrder) {
            TableColumn("Name", value: \.name) { file in
                HStack(spacing: 6) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: file.path))
                        .resizable()
                        .frame(width: 16, height: 16)
                    Text(file.name).lineLimit(1).truncationMode(.middle)
                }
            }
            .width(min: 180, ideal: 260)
            TableColumn("Size", value: \.size) { file in
                Text(file.size.formattedBytes).monospacedDigit()
            }
            .width(min: 70, ideal: 90)
            TableColumn("Modified", value: \.modified) { file in
                Text(file.modified, format: .dateTime.year().month(.abbreviated).day())
            }
            .width(min: 90, ideal: 110)
            TableColumn("Last Accessed", value: \.accessed) { file in
                Text(file.accessed, format: .relative(presentation: .named))
            }
            .width(min: 90, ideal: 120)
            TableColumn("Location", value: \.folder) { file in
                Text(file.folder).lineLimit(1).truncationMode(.head).foregroundStyle(.secondary)
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if !ids.isEmpty {
                if ids.count == 1, let id = ids.first { Button("Open") { Finder.open(id) } }
                Button("Reveal in Finder") { Finder.reveal(Array(ids)) }
                if ids.count == 1, let id = ids.first { Button("Copy Path") { Finder.copyPath(id) } }
                Divider()
                Button("Move to Trash…", role: .destructive) { confirmTrash(ids) }
            }
        } primaryAction: { ids in
            Finder.reveal(Array(ids))
        }
        .onDeleteCommand { confirmTrash(selection) }
        .onChange(of: model.sortOrder) { _, order in model.files.sort(using: order) }
        .overlay {
            if model.files.isEmpty {
                ContentUnavailableView("No files larger than \(model.threshold.formattedBytes)", systemImage: "checkmark.circle")
            }
        }
    }

    private var footer: some View {
        let selected = model.files.filter { selection.contains($0.id) }
        let total = model.files.reduce(0) { $0 + $1.size }
        return HStack {
            if selected.isEmpty {
                Text("\(model.files.count) files · \(total.formattedBytes)").foregroundStyle(.secondary)
            } else {
                Text("\(selected.count) selected")
                Text(selected.reduce(0) { $0 + $1.size }.formattedBytes).fontWeight(.semibold).monospacedDigit()
            }
            Spacer()
            Button("Reveal") { Finder.reveal(Array(selection)) }
                .disabled(selection.isEmpty)
            Button("Move to Trash…") { confirmTrash(selection) }
                .buttonStyle(.borderedProminent)
                .disabled(selection.isEmpty)
        }
        .padding(12)
    }

    private var confirmTitle: String {
        let size = model.files.filter { pending.contains($0.id) }.reduce(0) { $0 + $1.size }
        return "Move \(pending.count) file\(pending.count == 1 ? "" : "s") (\(size.formattedBytes)) to the Trash?"
    }

    private func confirmTrash(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        pending = ids
        showConfirm = true
    }

    private func performTrash() {
        let ids = pending
        pending = []
        Task {
            let result = await model.trash(ids: ids)
            selection.subtract(result.trashed)
            store.refreshVolumes()
            if !result.failures.isEmpty {
                errorMessage = result.failures.map { "\(($0.path as NSString).lastPathComponent): \($0.message)" }.joined(separator: "\n")
            }
        }
    }
}
