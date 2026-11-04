import SwiftUI

struct ExplorerView: View {
    @Environment(AppStore.self) private var store
    @State private var pendingTrash: [FileNode] = []
    @State private var showTrashConfirm = false
    @State private var errorMessage: String?

    private var model: ExplorerModel { store.explorer }

    var body: some View {
        Group {
            if model.isScanning {
                ScanProgressView(progress: model.progress, onCancel: model.cancel)
            } else if let current = model.current {
                content(current)
            } else {
                emptyState
            }
        }
        .navigationTitle("Explorer")
        .navigationSubtitle(model.root.map { $0.path.abbreviatingHome } ?? "")
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    Button("Home Folder") { model.scan(path: NSHomeDirectory()) }
                    Button("Entire Disk (Macintosh HD)") { model.scan(path: "/") }
                    Button("Applications") { model.scan(path: "/Applications") }
                    Divider()
                    Button("Choose Folder…") { chooseAndScan() }
                } label: {
                    Label("Scan", systemImage: "magnifyingglass")
                }
                Button { model.rescan() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                    .disabled(model.root == nil || model.isScanning)
            }
        }
        .confirmationDialog(trashTitle, isPresented: $showTrashConfirm) {
            Button("Move to Trash", role: .destructive) { performTrash() }
        } message: {
            Text("You can restore items from the Trash until it's emptied.")
        }
        .alert("Some items couldn't be moved", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Visualize your storage", systemImage: "square.grid.3x3.square")
        } description: {
            Text("Scan a folder to see what's taking up space as an interactive treemap.")
        } actions: {
            HStack {
                Button("Scan Home Folder") { model.scan(path: NSHomeDirectory()) }
                    .buttonStyle(.borderedProminent)
                Button("Scan Entire Disk") { model.scan(path: "/") }
                Button("Choose Folder…") { chooseAndScan() }
            }
            .controlSize(.large)
        }
    }

    @ViewBuilder
    private func content(_ current: FileNode) -> some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            BreadcrumbBar(node: current, onSelect: model.drill(into:), onUp: model.goUp)
            Divider()
            HSplitView {
                TreemapView(
                    node: current,
                    version: model.version,
                    highlighted: model.selection,
                    hovered: $model.hovered,
                    onActivate: activate,
                    onTrash: { confirmTrash([$0]) }
                )
                .frame(minWidth: 380)

                ChildList(
                    node: current,
                    version: model.version,
                    selection: $model.selection,
                    onOpen: { model.drill(into: $0) },
                    onTrash: confirmTrash
                )
                .frame(minWidth: 280, idealWidth: 340, maxWidth: 520)
            }
            Divider()
            StatusBar(current: current, focus: model.hovered ?? model.nodes(for: model.selection).first,
                      root: model.root, duration: model.scanDuration, scanned: model.progress.files)
        }
    }

    private func activate(_ node: FileNode) {
        if node.isDirectory && !node.children.isEmpty {
            model.drill(into: node)
        } else if node.kind != .aggregate {
            model.selection = [node.id]
        }
    }

    private func chooseAndScan() {
        if let path = Finder.chooseFolder() { model.scan(path: path) }
    }

    private var trashTitle: String {
        if pendingTrash.count == 1, let node = pendingTrash.first {
            return "Move “\(node.name)” (\(node.size.formattedBytes)) to the Trash?"
        }
        let total = pendingTrash.reduce(0) { $0 + $1.size }
        return "Move \(pendingTrash.count) items (\(total.formattedBytes)) to the Trash?"
    }

    private func confirmTrash(_ nodes: [FileNode]) {
        let nodes = nodes.filter { $0.kind != .aggregate }
        guard !nodes.isEmpty else { return }
        pendingTrash = nodes
        showTrashConfirm = true
    }

    private func performTrash() {
        let nodes = pendingTrash
        pendingTrash = []
        Task {
            let result = await model.trash(nodes)
            store.refreshVolumes()
            if !result.failures.isEmpty {
                errorMessage = result.failures.map { "\(($0.path as NSString).lastPathComponent): \($0.message)" }.joined(separator: "\n")
            }
        }
    }
}

struct ScanProgressView: View {
    let progress: ScanControl.Snapshot
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text("Scanning…").font(.title3.weight(.semibold))
            Text("\(progress.files.formatted()) files · \(progress.bytes.formattedBytes)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(progress.path.abbreviatingHome)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 520)
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct BreadcrumbBar: View {
    let node: FileNode
    var onSelect: (FileNode) -> Void
    var onUp: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onUp) { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless)
                .disabled(node.parent == nil)
                .help("Up one level")
                .keyboardShortcut(.upArrow, modifiers: .command)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        let chain = node.ancestors
                        ForEach(Array(chain.enumerated()), id: \.offset) { index, ancestor in
                            if index > 0 {
                                Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary)
                            }
                            Button(ancestor.name) { onSelect(ancestor) }
                                .buttonStyle(.borderless)
                                .fontWeight(ancestor === node ? .semibold : .regular)
                                .foregroundStyle(ancestor === node ? .primary : .secondary)
                                .id(index)
                        }
                    }
                }
                .onChange(of: ObjectIdentifier(node)) { proxy.scrollTo(node.ancestors.count - 1, anchor: .trailing) }
            }

            Spacer(minLength: 8)
            Text(node.size.formattedBytes)
                .font(.callout.weight(.semibold).monospacedDigit())
            Text("\(node.itemCount.formatted()) items")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct ChildList: View {
    let node: FileNode
    let version: Int
    @Binding var selection: Set<ObjectIdentifier>
    var onOpen: (FileNode) -> Void
    var onTrash: ([FileNode]) -> Void

    var body: some View {
        let children = node.children
        let total = max(node.size, 1)
        List(children, selection: $selection) { child in
            ChildRow(node: child, fraction: Double(child.size) / Double(total))
                .tag(child.id)
                .selectionDisabled(child.kind == .aggregate)
        }
        .contextMenu(forSelectionType: ObjectIdentifier.self) { ids in
            let nodes = children.filter { ids.contains($0.id) && $0.kind != .aggregate }
            if nodes.count == 1, let n = nodes.first {
                NodeMenu(node: n, onOpen: onOpen, onTrash: { onTrash([$0]) })
            } else if !nodes.isEmpty {
                Button("Reveal in Finder") { Finder.reveal(nodes.map(\.path)) }
                Divider()
                Button("Move \(nodes.count) Items to Trash…", role: .destructive) { onTrash(nodes) }
            }
        } primaryAction: { ids in
            if let n = children.first(where: { ids.contains($0.id) }) {
                n.isDirectory ? onOpen(n) : Finder.open(n.path)
            }
        }
        .onDeleteCommand {
            onTrash(children.filter { selection.contains($0.id) })
        }
        .id(version)
    }
}

struct ChildRow: View {
    let node: FileNode
    let fraction: Double

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(node.isDirectory ? Color.accentColor : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(node.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(node.kind == .aggregate ? .secondary : .primary)
                UsageBar(fraction: fraction, tint: node.isDirectory ? .accentColor : .secondary)
                    .frame(height: 3)
            }
            Text(node.size.formattedBytes)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 64, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }

    private var symbol: String {
        switch node.kind {
        case .directory: node.isAccessible ? "folder.fill" : "lock.fill"
        case .file: "doc"
        case .symlink: "arrow.turn.up.right"
        case .aggregate: "ellipsis.circle"
        }
    }
}

struct StatusBar: View {
    let current: FileNode
    let focus: FileNode?
    let root: FileNode?
    let duration: TimeInterval?
    let scanned: Int

    var body: some View {
        HStack(spacing: 12) {
            if let focus {
                Image(systemName: focus.isDirectory ? "folder" : "doc")
                    .foregroundStyle(.secondary)
                Text(focus.kind == .aggregate ? focus.name : focus.path.abbreviatingHome)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(focus.size.formattedBytes).fontWeight(.semibold).monospacedDigit()
                if current.size > 0 {
                    Text(Double(focus.size) / Double(current.size), format: .percent.precision(.fractionLength(1)))
                        .foregroundStyle(.secondary)
                }
                if focus.isDirectory {
                    Text("\(focus.itemCount.formatted()) items").foregroundStyle(.secondary)
                }
            } else {
                Text("Click a folder to zoom in · Right-click for actions")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let root, let duration {
                Text("\(root.size.formattedBytes) · \(scanned.formatted()) files in \(duration.formatted(.number.precision(.fractionLength(1))))s")
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
