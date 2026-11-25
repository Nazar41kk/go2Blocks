// Tests of UpdateManager on macOS (no iPad needed): ios/Tests/run-update-tests.sh
import Foundation

func fail(_ message: String) -> Never { print("FAIL: \(message)"); exit(1) }
func expect(_ ok: Bool, _ message: String) { if !ok { fail(message) } else { print("ok: \(message)") } }

@main struct Tests {
    static func main() async throws {
        let fm = FileManager.default
        let port = CommandLine.arguments[2]
        let tmp = fm.temporaryDirectory.appendingPathComponent("go2-update-test-\(UUID().uuidString)")
        let bundle = tmp.appendingPathComponent("bundle"), store = tmp.appendingPathComponent("store")
        try fm.createDirectory(at: bundle.appendingPathComponent("assets"), withIntermediateDirectories: true)
        try "<html>v0</html>".write(to: bundle.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try "same".write(to: bundle.appendingPathComponent("assets/a.js"), atomically: true, encoding: .utf8)
        try #"{"version":"v0"}"#.write(to: bundle.appendingPathComponent("version.json"), atomically: true, encoding: .utf8)
        let suite = "go2-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        func manager(_ feedName: String?) -> UpdateManager {
            UpdateManager(bundleRoot: bundle, storeRoot: store,
                          feed: feedName.map { URL(string: "http://localhost:\(port)/\($0)/manifest.json")! },
                          shellVersion: 2, defaults: defaults)
        }
        func fileOf(_ m: UpdateManager, _ path: String) -> String? { m.file(path).flatMap { try? String(contentsOf: $0, encoding: .utf8) } }

        var m = manager("v1")
        expect(m.currentVersion == "v0", "starts on the editor inside the app")
        var info = try await m.check()
        expect(info.available == "v1" && !info.needsNewApp, "sees the new version")
        expect(info.files == 3, "only the 3 changed files are to be downloaded (got \(info.files))")

        var steps: [Double] = []
        try await m.install { steps.append($0) }
        expect(steps.last == 1 && steps == steps.sorted(), "progress goes up to 1")
        expect(m.currentVersion == "v1" && m.activeRoot.path.hasPrefix(store.path), "uses the update")
        expect(fileOf(m, "index.html") == "<html>v1</html>", "the new index.html is served")
        expect(fileOf(m, "assets/a.js") == "same", "an unchanged file was kept (copied, not downloaded)")
        expect(fileOf(m, "assets/b.js") == "new", "a new file is there")
        expect(fm.fileExists(atPath: bundle.appendingPathComponent("index.html").path), "the app's own copy is untouched")
        info = try await m.check()
        expect(info.available == nil && info.files == 0, "nothing more to update")

        m = manager("v2-bad")      // a file whose hash does not match
        do { try await m.install { _ in }; fail("a wrong hash must be refused") } catch UpdateManager.Failure.badFile(let p) { expect(p == "assets/b.js", "refuses the file with a wrong hash") }
        expect(m.currentVersion == "v1", "a failed update changes nothing")
        expect(((try? fm.contentsOfDirectory(atPath: store.path)) ?? []).allSatisfy { !$0.hasPrefix("tmp-") }, "no half-downloaded folder is left")

        m = manager("v3-newapp")
        info = try await m.check()
        expect(info.needsNewApp, "an editor that needs a newer app says so")
        do { try await m.install { _ in }; fail("must not install") } catch UpdateManager.Failure.needsNewApp { expect(true, "and is not installed") }

        m = manager("v4-evil")
        do { _ = try await m.check(); fail("a path with .. must be refused") } catch UpdateManager.Failure.badManifest { expect(true, "refuses a manifest that reaches outside its folder") }
        m = manager(nil)
        do { _ = try await m.check(); fail("no address") } catch UpdateManager.Failure.notConfigured { expect(true, "without an address it says so") }
        m = manager("nowhere")
        do { _ = try await m.check(); fail("404") } catch UpdateManager.Failure.network { expect(true, "a missing manifest is a network failure") }

        // Starting up: an update that never reported ready is dropped on the next launch.
        m = manager("v1")
        try await m.install { _ in }                         // v1 again (already the one in use: copies it)
        let again = manager("v1"); again.beginLaunch()
        expect(again.currentVersion == "v0", "an update that never started is dropped at the next launch")
        expect(!fm.fileExists(atPath: store.path), "...and removed")
        try await again.install { _ in }
        again.confirmReady()
        let later = manager("v1"); later.beginLaunch()
        expect(later.currentVersion == "v1", "an update that started stays")
        later.confirmReady()
        let third = manager("v1"); third.beginLaunch(); third.confirmReady()
        expect(third.currentVersion == "v1", "and keeps staying")

        expect(UpdateManager.allowedFeed("https://example.org/x/manifest.json") != nil, "https feeds are allowed")
        expect(UpdateManager.allowedFeed("http://example.org/manifest.json") == nil, "plain http on the internet is not")
        expect(UpdateManager.allowedFeed("http://192.168.1.5/manifest.json") != nil, "plain http on the school's own network is")
        expect(UpdateManager.allowedFeed("") == nil, "an empty address is no feed")
        expect(UpdateManager.safe("assets/a.js") && !UpdateManager.safe("../x") && !UpdateManager.safe("/etc/passwd") && !UpdateManager.safe("a//b"), "path checks")
        print("ALL PASSED")
        try? fm.removeItem(at: tmp)
    }
}
