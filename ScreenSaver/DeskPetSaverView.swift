import ScreenSaver
import WebKit

/// DeskPet's screen saver: saver.html (the pet AI on standby, neural-network core) in a web view. System details
/// are read here; names and the task log come from the standby.json that DeskPet writes every minute to
/// ~/Library/Application Support/DeskPet (the screen saver host may read any file, read-only).
@objc(DeskPetSaverView)
final class DeskPetSaverView: ScreenSaverView {
    private var web: WKWebView?
    private var refresh: Timer?

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        animationTimeInterval = 1  // the page animates itself
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        let web = WKWebView(frame: bounds, configuration: WKWebViewConfiguration())
        web.autoresizingMask = [.width, .height]
        web.setValue(false, forKey: "drawsBackground")
        addSubview(web)
        self.web = web

        let bundle = Bundle(for: DeskPetSaverView.self)
        if let page = bundle.url(forResource: "saver", withExtension: "html"), let root = bundle.resourceURL,
           var comps = URLComponents(url: page, resolvingAgainstBaseURL: false) {
            comps.queryItems = Self.parameters().map { URLQueryItem(name: $0.key, value: $0.value) }
            if let url = comps.url { web.loadFileURL(url, allowingReadAccessTo: root) }
        }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.pushTasks() }
        RunLoop.main.add(timer, forMode: .common)
        refresh = timer
        // Since macOS 14 the screen saver host keeps running after the screen saver ends; quitting with it
        // avoids instances piling up (the host is started again for the next screen saver).
        if !isPreview {
            DistributedNotificationCenter.default().addObserver(self, selector: #selector(willStop),
                                                                name: Notification.Name("com.apple.screensaver.willstop"), object: nil)
        }
    }

    @objc private func willStop() {
        exit(0)
    }

    /// Mouse and keyboard belong to the screen saver engine (they end the screen saver).
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ rect: NSRect) {
        NSColor.black.setFill()
        rect.fill()
    }

    override var hasConfigureSheet: Bool { false }

    // MARK: Data

    /// The real home folder (NSHomeDirectory() points into the host's sandbox container).
    private static var home: String {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { return String(cString: dir) }
        return NSHomeDirectory()
    }

    private static func standby() -> [String: Any] {
        let url = URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/DeskPet/standby.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return json
    }

    private func pushTasks() {
        guard let tasks = Self.standby()["tasks"] as? [String],
              let data = try? JSONSerialization.data(withJSONObject: tasks),
              let list = String(data: data, encoding: .utf8) else { return }
        web?.evaluateJavaScript("window.DeskPetSaver && window.DeskPetSaver.setTasks(\(list))")
    }

    private static func parameters() -> [String: String] {
        let s = standby()
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let names = [26: "Tahoe", 15: "Sequoia", 14: "Sonoma", 13: "Ventura", 12: "Monterey", 11: "Big Sur"]
        var version = "\(v.majorVersion).\(v.minorVersion)"
        if v.patchVersion > 0 { version += ".\(v.patchVersion)" }
        var p: [String: String] = [
            "style": "c",
            "os": ["macOS", names[v.majorVersion], version].compactMap { $0 }.joined(separator: " "),
            "host": Host.current().localizedName ?? "Mac",
            "chip": sysctlString("machdep.cpu.brand_string") ?? "Apple Silicon",
            "cores": "\(ProcessInfo.processInfo.processorCount)",
            "mem": "\(ProcessInfo.processInfo.physicalMemory >> 30) GB",
            "displays": "\(NSScreen.screens.count)",
            "ai": s["ai"] as? String ?? "DeskPet",
            "aiLatin": s["aiLatin"] as? String ?? "DESKPET",
            "name": s["name"] as? String ?? (NSFullUserName().isEmpty ? NSUserName() : NSFullUserName()),
            "lang": s["lang"] as? String ?? (Locale.preferredLanguages.first ?? "en"),
        ]
        if let tasks = s["tasks"] as? [String], let data = try? JSONSerialization.data(withJSONObject: tasks),
           let list = String(data: data, encoding: .utf8) {
            p["log"] = list
        }
        return p
    }

    private static func sysctlString(_ key: String) -> String? {
        var size = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(key, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }
}
