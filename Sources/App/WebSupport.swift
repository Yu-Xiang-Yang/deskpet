import AppKit
import WebKit
import UniformTypeIdentifiers

/// Serves `deskpet://app/…` from the app bundle and the user's model directory:
///   /web/…              → Contents/Resources/web
///   /models/bundle/…    → Contents/Resources/models
///   /models/user/…      → ~/Library/Application Support/DeskPet/models
/// Using one custom origin lets WebGL load model textures without file:// restrictions.
final class AppSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "deskpet"

    static var webRoot: URL { Bundle.main.resourceURL!.appendingPathComponent("web", isDirectory: true) }
    static var bundledModels: URL { Bundle.main.resourceURL!.appendingPathComponent("models", isDirectory: true) }

    static func url(_ path: String) -> URL { URL(string: "\(scheme)://app/\(path)")! }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let file = Self.resolve(url.path) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        guard let data = try? Data(contentsOf: file) else {
            let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: [:])!
            task.didReceive(response)
            task.didFinish()
            return
        }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": mime, "Content-Length": String(data.count),
                                                      "Cache-Control": "no-cache"])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    /// Maps a request path onto a file, refusing anything outside the three roots.
    static func resolve(_ rawPath: String) -> URL? {
        let path = rawPath.removingPercentEncoding ?? rawPath
        let parts = path.split(separator: "/").map(String.init)
        guard !parts.contains(".."), let first = parts.first else { return nil }
        let root: URL
        var rest: ArraySlice<String>
        switch first {
        case "web":
            root = webRoot; rest = parts.dropFirst()
        case "models" where parts.count > 2 && parts[1] == "bundle":
            root = bundledModels; rest = parts.dropFirst(2)
        case "models" where parts.count > 2 && parts[1] == "user":
            root = AppPaths.userModelsDir; rest = parts.dropFirst(2)
        default:
            return nil
        }
        let file = rest.reduce(root) { $0.appendingPathComponent($1) }.standardizedFileURL
        guard file.path.hasPrefix(root.standardizedFileURL.path) else { return nil }
        // The Cubism Core may also be installed next to the user's models, without rebuilding the app.
        if first == "web", parts.last == "live2dcubismcore.min.js", !FileManager.default.fileExists(atPath: file.path) {
            return AppPaths.userModelsDir.appendingPathComponent("live2dcubismcore.min.js")
        }
        return file
    }
}

/// Bridges script messages without retaining the owner (WKUserContentController retains handlers).
final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

extension WKWebView {
    /// Calls `fn(args…)` with JSON-encoded arguments.
    func call(_ fn: String, _ args: JSON...) {
        let list = args.map { $0.compactString }.joined(separator: ",")
        evaluateJavaScript("\(fn)(\(list))", completionHandler: nil)
    }

    static func make(handlerName: String, handler: WKScriptMessageHandler) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(AppSchemeHandler(), forURLScheme: AppSchemeHandler.scheme)
        config.userContentController.add(WeakScriptHandler(handler), name: handlerName)
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        let webView = WKWebView(frame: .zero, configuration: config)
        if #available(macOS 13.3, *) { webView.isInspectable = true }
        return webView
    }
}

/// Live2D models found in the bundle and in the user's model directory.
struct PetModel: Identifiable, Equatable {
    var id: String          // "bundle/<dir>" or "user/<dir>"
    var name: String
    var modelURL: URL       // deskpet:// URL of the *.model3.json
    var map: JSON?

    static var cubismCoreInstalled: Bool {
        FileManager.default.fileExists(atPath: AppSchemeHandler.webRoot.appendingPathComponent("vendor/live2dcubismcore.min.js").path)
            || FileManager.default.fileExists(atPath: AppPaths.userModelsDir.appendingPathComponent("live2dcubismcore.min.js").path)
    }

    static func discover() -> [PetModel] {
        var result: [PetModel] = []
        for (source, root) in [("bundle", AppSchemeHandler.bundledModels), ("user", AppPaths.ensure(AppPaths.userModelsDir))] {
            let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for dir in dirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                guard let file = findModelFile(in: dir) else { continue }
                let relative = file.path.replacingOccurrences(of: root.path + "/", with: "")
                let encoded = relative.split(separator: "/").map {
                    String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
                }.joined(separator: "/")
                let map = (try? Data(contentsOf: dir.appendingPathComponent("pet-map.json"))).flatMap { try? JSON.parse($0) }
                result.append(PetModel(id: "\(source)/\(dir.lastPathComponent)", name: map?["name"]?.string ?? dir.lastPathComponent,
                                       modelURL: AppSchemeHandler.url("models/\(source)/\(encoded)"), map: map))
            }
        }
        return result
    }

    /// The first *.model3.json in the directory or one level below.
    private static func findModelFile(in dir: URL) -> URL? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return nil }
        for case let url as URL in enumerator {
            if enumerator.level > 2 { enumerator.skipDescendants(); continue }
            if url.lastPathComponent.hasSuffix(".model3.json") { return url }
        }
        return nil
    }
}
