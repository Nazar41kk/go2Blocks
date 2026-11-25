import CryptoKit
import Foundation

/// Updates of the editor (the web app in `web/`) from a web address, so the iPads do not have to be
/// reinstalled for every change. (Swift code itself still needs a normal install.)
///
/// `feed` is the address of manifest.json made by scripts/publish-update.py. An update is
/// downloaded into a folder of its own (only the files that changed), every file is checked against
/// its hash, and only then does the app switch to it. A new editor that never starts is dropped on
/// the next launch and the one inside the app is used again.
final class UpdateManager {
    struct Info {
        let current: String
        let available: String?      // nil: nothing newer
        let files: Int              // files to download
        let bytes: Int
        let needsNewApp: Bool       // the new editor needs a newer app (Swift side)
    }

    enum Failure: Error, Equatable {
        case notConfigured
        case badManifest(String)
        case needsNewApp
        case badFile(String)
        case network(String)
    }

    struct Manifest: Decodable {
        struct File: Decodable { let path: String; let sha256: String; let size: Int }
        let version: String
        let minShell: Int
        let files: [File]
    }

    /// The editor inside the app, and the folder updates are kept in.
    let bundleRoot: URL
    let storeRoot: URL
    var feed: URL?
    let shellVersion: Int
    private let defaults: UserDefaults
    private let session: URLSession
    private let activeKey = "go2.update.active"
    private let attemptsKey = "go2.update.attempts"

    init(bundleRoot: URL, storeRoot: URL, feed: URL?, shellVersion: Int, defaults: UserDefaults = .standard,
         session: URLSession? = nil) {
        self.bundleRoot = bundleRoot
        self.storeRoot = storeRoot
        self.feed = feed
        self.shellVersion = shellVersion
        self.defaults = defaults
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        self.session = session ?? URLSession(configuration: configuration)
    }

    /// The app's own manager: the update address comes from Info.plist (Go2UpdateURL).
    static let shared: UpdateManager = {
        let info = Bundle.main.infoDictionary ?? [:]
        let text = (info["Go2UpdateURL"] as? String) ?? ""
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return UpdateManager(
            bundleRoot: Bundle.main.resourceURL!.appendingPathComponent("web"),
            storeRoot: support.appendingPathComponent("Go2Blocks/web-update"),
            feed: UpdateManager.allowedFeed(text),
            shellVersion: Int((info["CFBundleVersion"] as? String) ?? "1") ?? 1)
    }()

    /// Only https (or the school's own network) may supply code for the app.
    static func allowedFeed(_ text: String) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespaces)), let host = url.host else { return nil }
        if url.scheme == "https" { return url }
        let local = host.hasPrefix("192.168.") || host.hasPrefix("10.") || host.hasPrefix("172.16.") || host == "localhost"
        return url.scheme == "http" && local ? url : nil
    }

    // MARK: which editor is in use

    /// Call once at launch. An update that was used last time but never reported that the editor
    /// started is dropped, so a broken update cannot lock the app.
    func beginLaunch() {
        guard defaults.string(forKey: activeKey) != nil else { return }
        if defaults.integer(forKey: attemptsKey) >= 1 { rollback() } else { defaults.set(1, forKey: attemptsKey) }
    }

    /// The editor started: this version is good.
    func confirmReady() { defaults.set(0, forKey: attemptsKey) }

    func rollback() {
        defaults.removeObject(forKey: activeKey)
        defaults.set(0, forKey: attemptsKey)
        try? FileManager.default.removeItem(at: storeRoot)
    }

    /// The folder to serve: the newest installed update, or the editor inside the app.
    var activeRoot: URL {
        if let name = defaults.string(forKey: activeKey) {
            let dir = storeRoot.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("index.html").path) { return dir }
        }
        return bundleRoot
    }

    /// A file of the editor: from the update if it has it, else from the app.
    func file(_ path: String) -> URL? {
        for root in [activeRoot, bundleRoot] {
            let url = root.appendingPathComponent(path).standardizedFileURL
            if url.path.hasPrefix(root.standardizedFileURL.path), FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    var currentVersion: String { Self.version(in: activeRoot) }

    static func version(in root: URL) -> String {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("version.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = json["version"] as? String else { return "unknown" }
        return version
    }

    // MARK: check and install

    func check() async throws -> Info {
        let manifest = try await fetchManifest()
        let current = currentVersion
        let changed = changedFiles(manifest)
        return Info(current: current, available: manifest.version == current ? nil : manifest.version,
                    files: changed.count, bytes: changed.reduce(0) { $0 + $1.size },
                    needsNewApp: manifest.minShell > shellVersion)
    }

    /// Download what changed, check it, switch to it. `progress` is 0...1. The page is reloaded by
    /// the caller afterwards.
    func install(progress: @escaping (Double) -> Void) async throws {
        let manifest = try await fetchManifest()
        if manifest.minShell > shellVersion { throw Failure.needsNewApp }
        let fm = FileManager.default
        try fm.createDirectory(at: storeRoot, withIntermediateDirectories: true)
        let temp = storeRoot.appendingPathComponent("tmp-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temp) }                      // gone after a failure; moved after success
        let toDownload = changedFiles(manifest)
        let totalBytes = max(toDownload.reduce(0) { $0 + $1.size }, 1)
        var doneBytes = 0
        progress(0)
        for file in manifest.files {
            let target = temp.appendingPathComponent(file.path)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let have = existing(file) {                          // unchanged: no need to download it again
                try fm.copyItem(at: have, to: target)
                continue
            }
            let data = try await download(file.path)
            guard data.count == file.size, Self.sha256(data) == file.sha256 else { throw Failure.badFile(file.path) }
            try data.write(to: target)
            doneBytes += data.count
            progress(min(Double(doneBytes) / Double(totalBytes), 0.99))
        }
        guard fm.fileExists(atPath: temp.appendingPathComponent("index.html").path) else { throw Failure.badManifest("no index.html") }
        let final = storeRoot.appendingPathComponent(manifest.version)
        try? fm.removeItem(at: final)
        try fm.moveItem(at: temp, to: final)
        defaults.set(manifest.version, forKey: activeKey)
        defaults.set(1, forKey: attemptsKey)                        // until the new editor says it started
        for other in (try? fm.contentsOfDirectory(atPath: storeRoot.path)) ?? [] where other != manifest.version {
            try? fm.removeItem(at: storeRoot.appendingPathComponent(other))
        }
        progress(1)
    }

    // MARK: helpers

    private func fetchManifest() async throws -> Manifest {
        guard let feed else { throw Failure.notConfigured }
        let data: Data
        do {
            let (body, response) = try await session.data(from: feed)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.network("HTTP error") }
            data = body
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.network(error.localizedDescription)
        }
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { throw Failure.badManifest("unreadable") }
        for file in manifest.files where !Self.safe(file.path) { throw Failure.badManifest("bad path \(file.path)") }
        guard manifest.files.contains(where: { $0.path == "index.html" }) else { throw Failure.badManifest("no index.html") }
        return manifest
    }

    static func safe(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\")
            && !path.split(separator: "/", omittingEmptySubsequences: false).contains { $0 == ".." || $0.isEmpty }
    }

    /// A copy of this file we already have (in the update in use, or in the app), if it is identical.
    private func existing(_ file: Manifest.File) -> URL? {
        for root in [activeRoot, bundleRoot] {
            let url = root.appendingPathComponent(file.path)
            if let data = try? Data(contentsOf: url), data.count == file.size, Self.sha256(data) == file.sha256 { return url }
        }
        return nil
    }

    private func changedFiles(_ manifest: Manifest) -> [Manifest.File] {
        manifest.files.filter { existing($0) == nil }
    }

    private func download(_ path: String) async throws -> Data {
        guard let feed else { throw Failure.notConfigured }
        var url = feed.deletingLastPathComponent().appendingPathComponent("files")
        for part in path.split(separator: "/") { url.appendPathComponent(String(part)) }
        do {
            let (body, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.network("HTTP error for \(path)") }
            return body
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.network(error.localizedDescription)
        }
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
