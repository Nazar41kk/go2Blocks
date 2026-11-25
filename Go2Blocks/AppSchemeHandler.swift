import UniformTypeIdentifiers
import WebKit

/// Serves the bundled web app (`web/`) under go2app://app/. A custom scheme gives the page a
/// real origin (module scripts and localStorage do not work from file://).
final class AppSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return task.didFailWithError(URLError(.badURL)) }
        let path = url.path.isEmpty || url.path == "/" ? "index.html" : String(url.path.dropFirst())
        // The newest installed update (UpdateManager), else the editor inside the app; a file the
        // update does not have comes from the app, and ../ cannot leave either folder.
        guard let file = UpdateManager.shared.file(path), let data = try? Data(contentsOf: file) else {
            // Say what is missing, on screen, instead of a white page.
            let text = "Go2 Blocks: not found in the app: \(path)\n(looked in \(UpdateManager.shared.activeRoot.path))"
            NSLog("%@", text)
            task.didReceive(HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: [
                "Content-Type": "text/plain; charset=utf-8", "Access-Control-Allow-Origin": "*"])!)
            task.didReceive(Data(text.utf8))
            task.didFinish()
            return
        }
        let type = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let mime = file.pathExtension == "js" ? "text/javascript" : type
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [
            "Content-Type": mime, "Content-Length": String(data.count), "Cache-Control": "no-store",
            "Access-Control-Allow-Origin": "*"])!)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
