import AVFoundation
import Network
import UIKit
import WebKit

/// The editor (the web app in `web/`) in a full-screen WKWebView, plus the one thing a page
/// cannot do itself: talk plain HTTP to the robot (`window.go2native`, see ui/src/local.ts).
final class ViewController: UIViewController, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandlerWithReply {
    private var webView: WKWebView!
    private var recorder: AVAudioRecorder?
    // The loading screen, over the web view until the page says it is ready (or 20 s have passed).
    private var splash: UIView?
    private var progressBar: UIProgressView?
    private var progressObservation: NSKeyValueObservation?
    private var creep: Timer?
    private let background = UIColor(red: 0.957, green: 0.969, blue: 0.984, alpha: 1)
    private let recordingURL = FileManager.default.temporaryDirectory.appendingPathComponent("go2-recording.m4a")
    /// The page's language (it tells us), for the dialogs this app shows itself.
    private var czech = Locale.preferredLanguages.first?.hasPrefix("cs") ?? false

    override func loadView() {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(AppSchemeHandler(), forURLScheme: "go2app")
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []     // the dances' music starts from Go
        let bridge = WKUserScript(source: ViewController.bridgeScript, injectionTime: .atDocumentStart,
                                  forMainFrameOnly: true)
        config.userContentController.addUserScript(bridge)
        config.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "go2")
        webView = WKWebView(frame: .zero, configuration: config)
        webView.uiDelegate = self
        webView.navigationDelegate = self
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.allowsLinkPreview = false
        if #available(iOS 16.4, *) { webView.isInspectable = true }
        // The web view is blank for a moment while iOS starts its web process: no white flash.
        webView.isOpaque = false
        webView.backgroundColor = background
        webView.scrollView.backgroundColor = background
        let container = UIView()
        container.backgroundColor = background
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        addSplash(to: container)
        view = container
    }

    // MARK: loading screen

    private func addSplash(to container: UIView) {
        let screen = UIView()
        screen.backgroundColor = background
        screen.translatesAutoresizingMaskIntoConstraints = false
        let logo = UIImageView(image: UIImage(named: "LaunchLogo"))
        logo.contentMode = .scaleAspectFit
        logo.translatesAutoresizingMaskIntoConstraints = false
        let bar = UIProgressView(progressViewStyle: .default)
        bar.progressTintColor = UIColor(red: 0.298, green: 0.592, blue: 1.0, alpha: 1)
        bar.trackTintColor = UIColor(red: 0.859, green: 0.886, blue: 0.933, alpha: 1)
        bar.layer.cornerRadius = 3
        bar.clipsToBounds = true
        bar.transform = CGAffineTransform(scaleX: 1, y: 2)
        bar.translatesAutoresizingMaskIntoConstraints = false
        let stack = UIStackView(arrangedSubviews: [logo, bar])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 32
        stack.translatesAutoresizingMaskIntoConstraints = false
        screen.addSubview(stack)
        container.addSubview(screen)
        NSLayoutConstraint.activate([
            screen.topAnchor.constraint(equalTo: container.topAnchor),
            screen.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            screen.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            screen.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.centerXAnchor.constraint(equalTo: screen.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: screen.centerYAnchor),
            logo.widthAnchor.constraint(equalToConstant: 200),
            logo.heightAnchor.constraint(equalToConstant: 200),
            bar.widthAnchor.constraint(equalToConstant: 260),
        ])
        splash = screen
        progressBar = bar
        // The line moves from the first moment (the web process takes seconds to start), creeping
        // towards 90 %; the page's real loading progress can push it further.
        creep = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let bar = self?.progressBar else { return }
            let next = bar.progress + (0.9 - bar.progress) * 0.03
            bar.setProgress(max(next, Float(self?.webView.estimatedProgress ?? 0) * 0.9), animated: true)
        }
        progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] web, _ in
            guard let bar = self?.progressBar else { return }
            bar.setProgress(max(bar.progress, Float(web.estimatedProgress) * 0.7), animated: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.finishSplash() }
    }

    private func finishSplash() {
        guard let screen = splash else { return }
        splash = nil
        creep?.invalidate()
        progressObservation = nil
        progressBar?.setProgress(1, animated: true)
        UIView.animate(withDuration: 0.35, delay: 0.15, options: [], animations: { screen.alpha = 0 },
                       completion: { _ in screen.removeFromSuperview() })
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        webView.load(URLRequest(url: URL(string: "go2app://app/index.html")!))
        // Leaving the app (home, app switcher, a call): stop the robot at once. The page also
        // stops it when it is hidden, but the page may not get to run that before it is frozen.
        NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.webView.evaluateJavaScript("window.go2Stop && window.go2Stop()", completionHandler: nil)
        }
    }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }

    // MARK: when the page cannot load, say so on screen

    private func showError(_ text: String) {
        NSLog("Go2 Blocks: %@", text)
        let escaped = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        webView.loadHTMLString("<meta name=viewport content='width=device-width'><pre style='font:16px Menlo;color:#b71c1c;padding:24px;white-space:pre-wrap'>Go2 Blocks could not start\n\n\(escaped)</pre>", baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showError(error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showError(error.localizedDescription)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.load(URLRequest(url: URL(string: "go2app://app/index.html")!))     // reload after a crash
    }

    // MARK: window.go2native

    private static let bridgeScript = """
    window.go2native = {
      post: (url, body, contentType, timeoutS) =>
        window.webkit.messageHandlers.go2.postMessage({op: "post", url, body, contentType, timeoutS}),
      portOpen: (ip, port) =>
        window.webkit.messageHandlers.go2.postMessage({op: "portOpen", ip, port}),
      ready: () => window.webkit.messageHandlers.go2.postMessage({op: "ready"}),
      updateInfo: () => window.webkit.messageHandlers.go2.postMessage({op: "updateInfo"}),
      updateCheck: () => window.webkit.messageHandlers.go2.postMessage({op: "updateCheck"}),
      updateInstall: () => window.webkit.messageHandlers.go2.postMessage({op: "updateInstall"}),
      updateRestart: () => window.webkit.messageHandlers.go2.postMessage({op: "updateRestart"}),
      setLanguage: (lang) => window.webkit.messageHandlers.go2.postMessage({op: "lang", lang}),
      recordStart: () => window.webkit.messageHandlers.go2.postMessage({op: "recordStart"}),
      recordStop: () => window.webkit.messageHandlers.go2.postMessage({op: "recordStop"}),
      recordCancel: () => window.webkit.messageHandlers.go2.postMessage({op: "recordCancel"}),
    };
    """

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard let m = message.body as? [String: Any], let op = m["op"] as? String else {
            return replyHandler(nil, "bad message")
        }
        switch op {
        case "post":
            guard let urlText = m["url"] as? String, let url = URL(string: urlText), Self.isLocal(url) else {
                return replyHandler(nil, "only the local network is allowed")
            }
            var request = URLRequest(url: url, timeoutInterval: (m["timeoutS"] as? Double) ?? 5)
            request.httpMethod = "POST"
            request.httpBody = Data(((m["body"] as? String) ?? "").utf8)
            if let type = m["contentType"] as? String { request.setValue(type, forHTTPHeaderField: "Content-Type") }
            let session = URLSession(configuration: .ephemeral)
            session.dataTask(with: request) { data, response, error in
                if let http = response as? HTTPURLResponse {
                    replyHandler(["status": http.statusCode,
                                  "body": String(decoding: data ?? Data(), as: UTF8.self)], nil)
                } else {
                    replyHandler(nil, error?.localizedDescription ?? "no answer")
                }
            }.resume()
        case "portOpen":
            guard let ip = m["ip"] as? String, let port = m["port"] as? Int,
                  let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else {
                return replyHandler(false, nil)
            }
            Self.probe(host: ip, port: nwPort) { replyHandler($0, nil) }
        case "recordStart":
            startRecording(replyHandler)
        case "recordStop":
            recorder?.stop()
            recorder = nil
            if let data = try? Data(contentsOf: recordingURL) {
                try? FileManager.default.removeItem(at: recordingURL)
                replyHandler(["data": data.base64EncodedString(), "mime": "audio/mp4"], nil)
            } else {
                replyHandler(nil, "no recording")
            }
        case "recordCancel":
            recorder?.stop()
            recorder = nil
            try? FileManager.default.removeItem(at: recordingURL)
            replyHandler(true, nil)
        case "updateInfo":
            let manager = UpdateManager.shared
            replyHandler(["webVersion": manager.currentVersion, "shellVersion": manager.shellVersion,
                          "configured": manager.feed != nil], nil)
        case "updateCheck":
            Task {
                do {
                    let info = try await UpdateManager.shared.check()
                    replyHandler(["ok": true, "current": info.current, "available": info.available.map { $0 as Any } ?? NSNull(),
                                  "files": info.files, "bytes": info.bytes, "needsNewApp": info.needsNewApp], nil)
                } catch {
                    replyHandler(["ok": false, "error": Self.updateErrorKey(error)], nil)
                }
            }
        case "updateInstall":
            Task {
                do {
                    try await UpdateManager.shared.install { fraction in
                        DispatchQueue.main.async {
                            self.webView.evaluateJavaScript("window.go2UpdateProgress && window.go2UpdateProgress(\(fraction))",
                                                            completionHandler: nil)
                        }
                    }
                    replyHandler(["ok": true], nil)
                } catch {
                    replyHandler(["ok": false, "error": Self.updateErrorKey(error)], nil)
                }
            }
        case "updateRestart":
            replyHandler(true, nil)
            DispatchQueue.main.async {      // the same address: the scheme handler now serves the update
                self.webView.load(URLRequest(url: URL(string: "go2app://app/index.html")!))
            }
        case "ready":
            UpdateManager.shared.confirmReady()      // this editor started: an update stays
            DispatchQueue.main.async { self.finishSplash() }
            replyHandler(true, nil)
        case "lang":
            czech = (m["lang"] as? String) == "cs"
            replyHandler(true, nil)
        default:
            replyHandler(nil, "unknown op")
        }
    }

    /// The page may only reach the robot's own network, never the internet.
    private static func isLocal(_ url: URL) -> Bool {
        guard url.scheme == "http", let host = url.host else { return false }
        return host.hasPrefix("192.168.") || host.hasPrefix("10.") || host.hasPrefix("172.16.")
    }

    private static func probe(host: String, port: NWEndpoint.Port, done: @escaping (Bool) -> Void) {
        guard isLocal(URL(string: "http://\(host)/")!) else { return done(false) }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        var finished = false
        let finish: (Bool) -> Void = { ok in
            DispatchQueue.main.async {
                guard !finished else { return }
                finished = true
                connection.cancel()
                done(ok)
            }
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: finish(true)
            case .failed, .cancelled: finish(false)
            default: break
            }
        }
        connection.start(queue: .global())
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { finish(false) }
    }

    private static func updateErrorKey(_ error: Error) -> String {
        guard let failure = error as? UpdateManager.Failure else { return "network" }
        switch failure {
        case .notConfigured: return "not_configured"
        case .needsNewApp: return "needs_new_app"
        case .badManifest, .badFile: return "bad_update"
        case .network: return "network"
        }
    }

    // MARK: recording (the page cannot use the microphone itself: it is not a "secure context")

    private func startRecording(_ reply: @escaping (Any?, String?) -> Void) {
        let begin: (Bool) -> Void = { granted in
            guard granted else { return DispatchQueue.main.async { reply(false, nil) } }
            DispatchQueue.global(qos: .userInitiated).async {      // session setup can block: not the main thread
                do {
                    let session = AVAudioSession.sharedInstance()
                    try session.setCategory(.playAndRecord, mode: .default,
                                            options: [.defaultToSpeaker, .allowBluetooth])
                    try session.setActive(true)
                    DispatchQueue.main.async {
                        do {
                            try? FileManager.default.removeItem(at: self.recordingURL)
                            let settings: [String: Any] = [
                                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 22050,
                                AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 48000,
                            ]
                            let recorder = try AVAudioRecorder(url: self.recordingURL, settings: settings)
                            // a little over the app's 30 s limit
                            guard recorder.record(forDuration: 31) else { return reply(false, nil) }
                            self.recorder = recorder
                            reply(true, nil)
                        } catch {
                            reply(false, nil)
                        }
                    }
                } catch {
                    DispatchQueue.main.async { reply(false, nil) }
                }
            }
        }
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission(completionHandler: begin)
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission(begin)
        }
    }

    // MARK: JavaScript dialogs (WKWebView answers false to confirm() unless the app shows it)

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: czech ? "Zrušit" : "Cancel", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        present(alert, animated: true)
    }
}
