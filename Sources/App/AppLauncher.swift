import AppKit

/// Opens an application by the name the owner uses: the localized name shown in Finder ("微信") or the bundle's
/// file name ("WeChat"), among the applications in the usual folders. It only launches the app; it never acts
/// inside it.
enum AppLauncher {
    private static var folders: [URL] {
        let fm = FileManager.default
        return ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
            .map { URL(fileURLWithPath: $0) }
    }

    /// The best match: an exact name first, then a name that starts with or contains the query.
    static func find(_ name: String) -> URL? {
        let query = normalized(name.replacingOccurrences(of: ".app", with: ""))
        guard !query.isEmpty else { return nil }
        let fm = FileManager.default
        var candidates: [(rank: Int, url: URL)] = []
        let finder = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        for folder in folders {
            guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { continue }
            for url in items + (folder == folders[0] ? [finder] : []) where url.pathExtension == "app" {
                let names = Self.names(url).map(normalized)
                if names.contains(query) { candidates.append((0, url)) }
                else if names.contains(where: { $0.hasPrefix(query) }) { candidates.append((1, url)) }
                else if query.count >= 2, names.contains(where: { $0.contains(query) }) { candidates.append((2, url)) }
            }
        }
        return candidates.min { ($0.rank, $0.url.path.count) < ($1.rank, $1.url.path.count) }?.url
    }

    /// Opens the app; the completion reports what happened, for the pet to say.
    static func open(_ name: String, completion: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {  // reading the bundles takes a moment
            let url = find(name)
            DispatchQueue.main.async { launch(url, name, completion) }
        }
    }

    private static func launch(_ url: URL?, _ name: String, _ completion: @escaping (String) -> Void) {
        guard let url else {
            completion(tr("没找到叫“\(name)”的应用。", "I couldn't find an app called “\(name)”."))
            return
        }
        let title = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            DispatchQueue.main.async {
                completion(error == nil ? tr("已打开\(title)。", "Opened \(title).")
                                        : tr("打不开\(title)：\(error!.localizedDescription)", "Couldn't open \(title): \(error!.localizedDescription)"))
            }
        }
    }

    /// The names an app goes by: its file name, its Finder name, and the bundle names in Info.plist and in the
    /// localized InfoPlist.strings (third-party apps) or InfoPlist.loctable (Apple's apps), in every language.
    private static func names(_ url: URL) -> Set<String> {
        var names: Set<String> = [url.deletingPathExtension().lastPathComponent,
                                  FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")]
        let keys = ["CFBundleDisplayName", "CFBundleName"]
        func take(_ dict: [String: Any]?) { keys.forEach { if let n = dict?[$0] as? String, !n.isEmpty { names.insert(n) } } }
        let contents = url.appendingPathComponent("Contents")
        take(NSDictionary(contentsOf: contents.appendingPathComponent("Info.plist")) as? [String: Any])
        let resources = contents.appendingPathComponent("Resources")
        if let table = NSDictionary(contentsOf: resources.appendingPathComponent("InfoPlist.loctable")) as? [String: Any] {
            table.values.forEach { take($0 as? [String: Any]) }
        }
        let lprojs = (try? FileManager.default.contentsOfDirectory(atPath: resources.path))?.filter { $0.hasSuffix(".lproj") } ?? []
        for lproj in lprojs {
            take(NSDictionary(contentsOf: resources.appendingPathComponent("\(lproj)/InfoPlist.strings")) as? [String: Any])
        }
        return names
    }

    private static func normalized(_ s: String) -> String {
        s.lowercased().filter { !$0.isWhitespace }
    }
}
