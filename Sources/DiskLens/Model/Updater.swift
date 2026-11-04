import AppKit
import Foundation
import Observation

struct GitHubRelease: Decodable, Sendable {
    struct Asset: Decodable, Sendable {
        let name: String
        let browserDownloadUrl: URL
        let size: Int64
    }

    let tagName: String
    let name: String?
    let body: String?
    let htmlUrl: URL
    let publishedAt: Date?
    let assets: [Asset]

    var version: String { tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName }
    var dmg: Asset? { assets.first { $0.name.lowercased().hasSuffix(".dmg") } }
}

enum AppVersion {
    static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0"
    }

    /// Numeric, component-wise comparison ("1.0.10" > "1.0.9").
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

/// Checks GitHub Releases for a newer build, downloads its DMG with progress,
/// and swaps the running app for the new one.
@MainActor
@Observable
final class Updater {
    nonisolated static let repository = "ruck-syu/DiskLens"

    /// GitHub's "latest release" endpoint. DISKLENS_UPDATE_URL overrides it for testing.
    nonisolated static var releaseFeedURL: URL {
        if let override = ProcessInfo.processInfo.environment["DISKLENS_UPDATE_URL"], let url = URL(string: override) {
            return url
        }
        return URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    }

    enum State {
        case idle
        case checking
        case upToDate
        case available(GitHubRelease)
        case downloading(GitHubRelease)
        case downloaded(GitHubRelease, URL)
        case installing
        case failed(String)
    }

    var state: State = .idle
    var isSheetPresented = false
    /// Set whenever a newer release is known, so the sidebar can offer it.
    var availableRelease: GitHubRelease?

    var bytesReceived: Int64 = 0
    var bytesExpected: Int64 = 0
    var bytesPerSecond: Double = 0

    var automaticallyChecks: Bool = UserDefaults.standard.object(forKey: "autoCheckUpdates") as? Bool ?? true {
        didSet { UserDefaults.standard.set(automaticallyChecks, forKey: "autoCheckUpdates") }
    }

    var fractionCompleted: Double {
        bytesExpected > 0 ? min(1, Double(bytesReceived) / Double(bytesExpected)) : 0
    }

    @ObservationIgnored private var downloadTask: URLSessionDownloadTask?
    @ObservationIgnored private var session: URLSession?
    @ObservationIgnored private var didAutoCheck = false

    // MARK: Checking

    func checkFromMenu() {
        isSheetPresented = true
        switch state {
        case .downloading, .downloaded, .installing: return
        default: Task { await check(userInitiated: true) }
        }
    }

    func autoCheckOnLaunch() async {
        guard automaticallyChecks, !didAutoCheck else { return }
        didAutoCheck = true
        try? await Task.sleep(for: .seconds(3))
        await check(userInitiated: false)
    }

    func check(userInitiated: Bool) async {
        state = .checking
        do {
            let release = try await Self.fetchLatestRelease()
            if AppVersion.isNewer(release.version, than: AppVersion.current), release.dmg != nil {
                availableRelease = release
                state = .available(release)
            } else {
                availableRelease = nil
                state = .upToDate
            }
        } catch {
            state = userInitiated ? .failed(error.localizedDescription) : .idle
        }
    }

    nonisolated private static func fetchLatestRelease() async throws -> GitHubRelease {
        var request = URLRequest(url: releaseFeedURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("DiskLens/\(AppVersion.current)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200: break
        case 404: throw UpdateError("No published release was found on GitHub. If the repository is private, the app can't see its releases.")
        case 403, 429:
            // The anonymous API allows 60 calls/hour per IP, which shared IPs (VPNs,
            // iCloud Private Relay, offices) exhaust. github.com itself isn't limited.
            return try await fetchLatestReleaseWithoutAPI()
        default: throw UpdateError("GitHub returned an unexpected response (HTTP \(status)).")
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(GitHubRelease.self, from: data)
    }

    /// Finds the latest release from github.com's `/releases/latest` redirect
    /// and builds the DMG URL from the workflow's naming scheme.
    nonisolated private static func fetchLatestReleaseWithoutAPI() async throws -> GitHubRelease {
        var request = URLRequest(url: URL(string: "https://github.com/\(repository)/releases/latest")!)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 20
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let finalURL = response.url, finalURL.path.contains("/releases/tag/") else {
            throw UpdateError("No published release was found on GitHub.")
        }
        let tag = finalURL.lastPathComponent
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let dmgURL = URL(string: "https://github.com/\(repository)/releases/download/\(tag)/DiskLens-\(version).dmg")!
        return GitHubRelease(
            tagName: tag,
            name: "DiskLens \(version)",
            body: nil,
            htmlUrl: finalURL,
            publishedAt: nil,
            assets: [.init(name: "DiskLens-\(version).dmg", browserDownloadUrl: dmgURL, size: 0)]
        )
    }

    // MARK: Downloading

    func download(_ release: GitHubRelease) {
        guard let asset = release.dmg else { return }
        bytesReceived = 0
        bytesExpected = asset.size
        bytesPerSecond = 0
        state = .downloading(release)

        let started = Date()
        let delegate = DownloadDelegate(
            onProgress: { [weak self] received, expected in
                Task { @MainActor in
                    guard let self, case .downloading = self.state else { return }
                    self.bytesReceived = received
                    if expected > 0 { self.bytesExpected = expected }
                    let elapsed = Date().timeIntervalSince(started)
                    if elapsed > 0.5 { self.bytesPerSecond = Double(received) / elapsed }
                }
            },
            onFinish: { [weak self] result in
                Task { @MainActor in
                    guard let self, case .downloading = self.state else { return }
                    self.session?.finishTasksAndInvalidate()
                    self.session = nil
                    switch result {
                    case .success(let url):
                        self.bytesReceived = self.bytesExpected
                        self.state = .downloaded(release, url)
                    case .failure(let error):
                        self.state = .failed("The download failed: \(error.localizedDescription)")
                    }
                }
            }
        )
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        self.session = session
        let task = session.downloadTask(with: asset.browserDownloadUrl)
        downloadTask = task
        task.resume()
    }

    func cancelDownload() {
        guard case .downloading(let release) = state else { return }
        downloadTask?.cancel()
        session?.invalidateAndCancel()
        session = nil
        state = .available(release)
    }

    // MARK: Installing

    func installAndRelaunch(dmg: URL) {
        state = .installing
        let target = Bundle.main.bundleURL
        let canReplace = target.pathExtension == "app"
            && FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path)
            && FileManager.default.isWritableFile(atPath: target.path)

        guard canReplace else {
            NSWorkspace.shared.open(dmg)
            state = .failed("DiskLens can't replace itself in its current location, so the disk image was opened. Drag DiskLens to Applications to finish updating.")
            return
        }

        Task {
            do {
                let staged = try await Task.detached { try Self.stageApp(from: dmg) }.value
                try Self.launchReplacer(newApp: staged, target: target, waitingFor: ProcessInfo.processInfo.processIdentifier)
                NSApp.terminate(nil)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// Mounts the DMG, copies the app out to a temp folder, and unmounts.
    nonisolated static func stageApp(from dmg: URL) throws -> URL {
        let attach = try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-noautoopen", "-readonly", "-plist", dmg.path])
        guard let plist = try PropertyListSerialization.propertyList(from: attach, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let mount = entities.compactMap({ $0["mount-point"] as? String }).first
        else { throw UpdateError("Couldn't open the downloaded disk image.") }
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mount, "-force"]) }

        let contents = try FileManager.default.contentsOfDirectory(atPath: mount)
        guard let appName = contents.first(where: { $0.hasSuffix(".app") }) else {
            throw UpdateError("The disk image doesn't contain an app.")
        }
        let stagingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskLensUpdate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let staged = stagingDir.appendingPathComponent("DiskLens.app")
        _ = try run("/usr/bin/ditto", [(mount as NSString).appendingPathComponent(appName), staged.path])
        _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])
        try? FileManager.default.removeItem(at: dmg)
        return staged
    }

    /// Starts a small script that waits for this process to quit, swaps the
    /// app bundle (rolling back on failure), and relaunches it.
    nonisolated static func launchReplacer(newApp: URL, target: URL, waitingFor pid: Int32) throws {
        let script = """
        #!/bin/bash
        PID="$1"; NEW="$2"; TARGET="$3"
        while kill -0 "$PID" 2>/dev/null; do sleep 0.2; done
        rm -rf "$TARGET.old"
        if mv "$TARGET" "$TARGET.old" && ditto "$NEW" "$TARGET"; then
          rm -rf "$TARGET.old"
        else
          rm -rf "$TARGET"; mv "$TARGET.old" "$TARGET"
        fi
        rm -rf "$(dirname "$NEW")"
        open "$TARGET"
        rm -f "$0"
        """
        let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("disklens-update-\(UUID().uuidString).sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path, String(pid), newApp.path, target.path]
        try process.run()
    }

    @discardableResult
    nonisolated private static func run(_ tool: String, _ args: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError("\((tool as NSString).lastPathComponent) failed (exit \(process.terminationStatus)).")
        }
        return data
    }
}

struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Bridges URLSession's delegate callbacks to closures.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let onProgress: (Int64, Int64) -> Void
    let onFinish: (Result<URL, Error>) -> Void
    private var finished = false

    init(onProgress: @escaping (Int64, Int64) -> Void, onFinish: @escaping (Result<URL, Error>) -> Void) {
        self.onProgress = onProgress
        self.onFinish = onFinish
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temp file is deleted when this method returns, so move it now.
        finished = true
        if let status = (downloadTask.response as? HTTPURLResponse)?.statusCode, status != 200 {
            onFinish(.failure(UpdateError("Server returned HTTP \(status).")))
            return
        }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("DiskLens-update-\(UUID().uuidString).dmg")
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            onFinish(.success(destination))
        } catch {
            onFinish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !finished, let error else { return }
        if (error as NSError).code == NSURLErrorCancelled { return }
        onFinish(.failure(error))
    }
}
