import SwiftUI

/// The "Check for Updates" sheet.
struct UpdateSheet: View {
    @Bindable var updater: Updater
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.title3.weight(.semibold))
                    Text("You're running DiskLens \(AppVersion.current).")
                        .foregroundStyle(.secondary)
                }
            }

            content

            Divider()
            HStack {
                Toggle("Check for updates automatically", isOn: $updater.automaticallyChecks)
                    .toggleStyle(.checkbox)
                    .font(.callout)
                Spacer()
                buttons
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private var title: String {
        switch updater.state {
        case .idle, .checking: "Checking for updates…"
        case .upToDate: "DiskLens is up to date"
        case .available(let r): "DiskLens \(r.version) is available"
        case .downloading(let r): "Downloading DiskLens \(r.version)…"
        case .downloaded(let r, _): "DiskLens \(r.version) is ready to install"
        case .installing: "Installing update…"
        case .failed: "Couldn't update"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch updater.state {
        case .idle, .checking, .installing:
            ProgressView().progressViewStyle(.linear)
        case .upToDate:
            EmptyView()
        case .available(let release):
            ReleaseNotes(release: release)
        case .downloading:
            DownloadProgress(updater: updater)
        case .downloaded(let release, _):
            ReleaseNotes(release: release)
            Text("DiskLens will quit, update itself, and reopen.")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var buttons: some View {
        switch updater.state {
        case .available(let release):
            Button("Later") { dismiss() }
            Button("Download Update") { updater.download(release) }
                .keyboardShortcut(.defaultAction)
        case .downloading:
            Button("Cancel Download") { updater.cancelDownload() }
            Button("Hide") { dismiss() }
                .keyboardShortcut(.defaultAction)
        case .downloaded(_, let dmg):
            Button("Later") { dismiss() }
            Button("Install and Relaunch") { updater.installAndRelaunch(dmg: dmg) }
                .keyboardShortcut(.defaultAction)
        case .failed:
            Button("Close") { dismiss() }
            Button("Try Again") { Task { await updater.check(userInitiated: true) } }
                .keyboardShortcut(.defaultAction)
        case .installing, .checking, .idle:
            Button("Close") { dismiss() }.disabled(true)
        case .upToDate:
            Button("OK") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
    }
}

private struct ReleaseNotes: View {
    let release: GitHubRelease

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("What's new").font(.headline)
                Spacer()
                if let size = release.dmg?.size {
                    Text(size.formattedBytes).font(.caption).foregroundStyle(.secondary)
                }
                Link("View on GitHub", destination: release.htmlUrl).font(.caption)
            }
            ScrollView {
                Text(notes)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: 140)
            .padding(8)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var notes: AttributedString {
        let text = release.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { return AttributedString("No release notes.") }
        return (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

/// Progress bar with bytes, percentage, speed and time remaining.
struct DownloadProgress: View {
    let updater: Updater
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: updater.fractionCompleted)
                .progressViewStyle(.linear)
                .controlSize(compact ? .small : .regular)
            HStack {
                Text("\(updater.bytesReceived.formattedBytes) of \(updater.bytesExpected.formattedBytes)")
                Spacer()
                if !compact, let remaining {
                    Text(remaining)
                }
                Text(updater.fractionCompleted, format: .percent.precision(.fractionLength(0)))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var remaining: String? {
        guard updater.bytesPerSecond > 0 else { return nil }
        let speed = Int64(updater.bytesPerSecond).formattedBytes + "/s"
        let seconds = Double(updater.bytesExpected - updater.bytesReceived) / updater.bytesPerSecond
        guard seconds.isFinite, seconds >= 1 else { return speed }
        return "\(speed) · \(Duration.seconds(seconds).formatted(.units(allowed: [.minutes, .seconds], width: .narrow))) left"
    }
}

/// Small card at the bottom of the sidebar when an update is available or downloading.
struct SidebarUpdateBadge: View {
    let updater: Updater

    var body: some View {
        switch updater.state {
        case .downloading(let release):
            card {
                Text("Downloading \(release.version)…").font(.caption.weight(.medium))
                DownloadProgress(updater: updater, compact: true)
            }
        case .downloaded(let release, _):
            card {
                Text("DiskLens \(release.version) is ready").font(.caption.weight(.medium))
                Button("Install and Relaunch") { updater.isSheetPresented = true }
                    .controlSize(.small)
            }
        default:
            if let release = updater.availableRelease, case .available = updater.state {
                card {
                    Text("DiskLens \(release.version) is available").font(.caption.weight(.medium))
                    Button("Update…") { updater.isSheetPresented = true }
                        .controlSize(.small)
                }
            }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6, content: content)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 10)
    }
}
