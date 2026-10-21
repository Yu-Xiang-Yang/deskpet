import AppKit
import WebKit

/// The login intro (web/intro.html: terminal log → glitch → white-and-gold sanctum) on every screen, above all
/// windows. It ends by itself after about 6 s, on any key or click, and at the latest after 12 s.
@MainActor
final class BootIntro: NSObject, WKScriptMessageHandler {
    private var windows: [NSWindow] = []
    private var finishing = false
    private var monitor: Any?
    private var completion: (() -> Void)?

    static let hardTimeout: TimeInterval = 12

    /// Plays once per system start (the boot time is remembered), when enabled in the settings.
    static var dueThisBoot: Bool {
        AppSettings.shared.bootIntro && UserDefaults.standard.double(forKey: "bootIntroLastBoot") != bootTime
    }

    static func markPlayedThisBoot() {
        UserDefaults.standard.set(bootTime, forKey: "bootIntroLastBoot")
    }

    private static var bootTime: Double {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 else { return 0 }
        return Double(tv.tv_sec)
    }

    func play(completion: @escaping () -> Void) {
        guard windows.isEmpty else { return }
        self.completion = completion
        var comps = URLComponents(url: AppSchemeHandler.url("web/intro.html"), resolvingAgainstBaseURL: false)!
        comps.queryItems = Self.systemInfo().map { URLQueryItem(name: $0.key, value: $0.value) }
        for screen in NSScreen.screens {
            let w = IntroWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.level = .screenSaver
            w.backgroundColor = .black
            w.isOpaque = true
            w.isReleasedWhenClosed = false
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            let web = WKWebView.make(handlerName: "boot", handler: self)
            web.setValue(false, forKey: "drawsBackground")
            web.frame = NSRect(origin: .zero, size: screen.frame.size)
            web.autoresizingMask = [.width, .height]
            w.contentView = web
            if let url = comps.url { web.load(URLRequest(url: url)) }
            w.setFrame(screen.frame, display: true)
            w.orderFrontRegardless()
            windows.append(w)
        }
        windows.first?.makeKey()
        NSApp.activate(ignoringOtherApps: true)
        NSCursor.hide()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.finish()
            return nil
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hardTimeout) { [weak self] in self?.finish() }
    }

    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        // "done" (0.6 s before the end, time to fade) or "skip".
        DispatchQueue.main.async { MainActor.assumeIsolated { self.finish() } }
    }

    private func finish() {
        guard !finishing, !windows.isEmpty else { return }
        finishing = true
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.6
            windows.forEach { $0.animator().alphaValue = 0 }
        }, completionHandler: {
            MainActor.assumeIsolated {
                NSCursor.unhide()
                self.windows.forEach { $0.orderOut(nil) }
                self.windows = []
                self.finishing = false
                let done = self.completion
                self.completion = nil
                done?()
            }
        })
    }

    private static func systemInfo() -> [String: String] {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let names = [26: "Tahoe", 15: "Sequoia", 14: "Sonoma", 13: "Ventura", 12: "Monterey", 11: "Big Sur"]
        var version = "\(v.majorVersion).\(v.minorVersion)"
        if v.patchVersion > 0 { version += ".\(v.patchVersion)" }
        let os = ["macOS", names[v.majorVersion], version].compactMap { $0 }.joined(separator: " ")
        var u = utsname()
        uname(&u)
        let darwin = withUnsafeBytes(of: &u.release) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        let settings = AppSettings.shared
        let called = settings.userName.trimmingCharacters(in: .whitespaces)
        let name = called.isEmpty ? (NSFullUserName().split(separator: " ").first.map(String.init) ?? NSUserName()) : called
        return [
            "name": name,
            "greeting": tr("欢迎回来，\(name)", "Welcome back, \(name)"),
            "os": os,
            "host": Host.current().localizedName ?? "Mac",
            "chip": sysctlString("machdep.cpu.brand_string") ?? "Apple Silicon",
            "mem": "\(ProcessInfo.processInfo.physicalMemory >> 30) GB",
            "darwin": darwin,
            "displays": "\(NSScreen.screens.count)",
            "user": NSUserName(),
        ]
    }

    private static func sysctlString(_ key: String) -> String? {
        var size = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(key, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }
}

/// Borderless windows cannot become key by default; the intro needs key events to be skipped.
private final class IntroWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
