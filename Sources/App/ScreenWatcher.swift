import AppKit
import ScreenCaptureKit

/// Looks at the owner's screen now and then (Settings → Reminders → Watching the screen): a screenshot of the display
/// under the pointer, without the pet's own windows, goes to the model, which says in one sentence what the owner is
/// doing. Only that sentence is kept, in memory; the screenshot is never written to disk. Apps the owner lists are not
/// captured, and an unchanged scene (same app and window) is not looked at again for half an hour.
final class ScreenWatcher: ObservableObject {
    static let shared = ScreenWatcher()

    /// The latest glances, newest first (at most 12; not saved).
    @Published private(set) var glances: [ScreenGlance] = []
    private let lock = NSLock()
    private var latestGlance: ScreenGlance?
    private let settings = AppSettings.shared
    private var timer: Timer?
    private(set) var looking = false
    private var lastLook = Date.distantPast
    /// The last app other than the pet that came to the front: what the owner works in while the pet's chat box is open.
    private var lastOtherApp: NSRunningApplication?
    /// Whether the app lets the pet look now (screen unlocked, no intro, the pet awake).
    var mayLook: (() -> Bool)?

    /// Test runs: a JPEG file used instead of a screenshot (DESKPET_SCREENSHOT), so that no permission is needed.
    private static let testImage: String? = ProcessInfo.processInfo.environment["DESKPET_DIR"] != nil
        ? ProcessInfo.processInfo.environment["DESKPET_SCREENSHOT"] : nil

    /// The latest glance, from any thread.
    var latest: ScreenGlance? { lock.withLock { latestGlance } }

    /// The latest glance for the model's context (at most 20 minutes old), from any thread.
    var contextLine: String? { ScreenGlances.contextLine(latest, now: Date()) }

    /// Whether macOS lets the app record the screen (System Settings → Privacy & Security → Screen & System Audio Recording).
    static var permitted: Bool { testImage != nil || CGPreflightScreenCaptureAccess() }

    /// Asks macOS for screen recording; the first time, the system lists the app in Privacy & Security for the owner to allow.
    static func requestPermission() { _ = CGRequestScreenCaptureAccess() }

    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            self?.lastOtherApp = app
        }
        if settings.screenAwareness, !Self.permitted { Self.requestPermission() }
    }

    /// Every minute: looks once the interval has passed, while the owner is at the computer.
    private func tick() {
        guard settings.screenAwareness, !looking, Date().timeIntervalSince(lastLook) >= Double(max(1, settings.screenMinutes)) * 60,
              PetBrain.idleSeconds < 120, mayLook?() ?? true, Self.permitted,
              Providers.configured(settings, kind: settings.screenProviderKind) else { return }
        look()
    }

    private func record(_ glance: ScreenGlance, replacingLatest: Bool = false) {
        lock.withLock { latestGlance = glance }
        var list = glances
        if replacingLatest, !list.isEmpty { list.removeFirst() }
        glances = Array(([glance] + list).prefix(12))
    }

    /// Looks now; `done` gets what was seen, or why nothing was.
    func look(done: ((String) -> Void)? = nil) {
        guard !looking else { done?(tr("正在看…", "Already looking…")); return }
        guard Self.permitted else {
            Self.requestPermission()
            done?(tr("尚未获得屏幕录制权限：请在“系统设置 → 隐私与安全性 → 录屏与系统录音”中允许 DeskPet，然后重启桌宠。",
                     "No screen recording permission: allow DeskPet under System Settings → Privacy & Security → Screen & System Audio Recording, then restart the pet."))
            return
        }
        let kind = settings.screenProviderKind
        guard Providers.configured(settings, kind: kind) else { done?(tr("所选的识图服务尚未配置。", "The service chosen for screenshots is not configured.")); return }
        let now = Date()
        lastLook = now
        var front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier == ProcessInfo.processInfo.processIdentifier, let other = lastOtherApp, !other.isTerminated { front = other }
        let app = front?.localizedName ?? tr("未知应用", "an unknown app")
        let title = front.flatMap { Self.windowTitle(pid: $0.processIdentifier) }
        if ScreenGlances.excluded(name: app, list: settings.screenExcluded) {
            let glance = ScreenGlance(date: now, looked: now, app: app, activity: "在使用\(app)（按设置未截屏）", kind: "other", unseen: true)
            record(glance)
            done?(glance.activity)
            return
        }
        if var same = latest, ScreenGlances.sameScene(same, app: app, title: title, now: now) {
            // Same app and window as before: the last account still holds.
            same.date = now
            record(same, replacingLatest: glances.first?.id == same.id)
            done?(same.activity)
            return
        }
        looking = true
        let display = Self.displayUnderPointer()
        let system = Self.prompt(petName: settings.petName)
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd EEEE HH:mm"
        let text = "[当前时间：\(f.string(from: now))] 前台应用：\(app)" + (title.map { "；窗口标题：\($0)" } ?? "")
            + "\n请描述主人此刻在做什么，只输出 JSON。"
        Task { @MainActor [weak self] in
            guard let self else { return }
            var outcome: String
            do {
                let jpeg = try await Self.capture(display: display)
                let provider = try await Providers.currentInBackground(self.settings, kind: kind)
                let turn = try await provider.send(LLMRequest(system: system, messages: [provider.imageMessage(text, jpeg: jpeg)], effort: "low",
                                                              noThinking: true, maxTokens: 500, jsonSchema: ScreenGlances.schema))
                if let seen = ScreenGlances.parse(turn.text) {
                    self.record(ScreenGlance(date: now, looked: now, app: app, title: title, activity: seen.activity, kind: seen.kind))
                    outcome = seen.activity
                } else {
                    outcome = tr("模型的描述无法解析。", "The model's account could not be read.")
                }
            } catch {
                outcome = tr("观察屏幕失败：", "Looking at the screen failed: ") + error.localizedDescription
            }
            self.looking = false
            done?(outcome)
        }
    }

    static func prompt(petName: String) -> String {
        """
        你是桌面宠物「\(petName)」的视觉模块。【观察屏幕】根据主人电脑屏幕的截图，用一句话具体描述主人此刻在做什么：所用应用、\
        正在进行的任务、内容的主题与要点，例如“在 Xcode 里调试桌宠的 Swift 代码”“在 B 站看猫咪视频”“在微信里和同学商量周三组会的安排”。\
        密码、验证码与银行卡号等凭据不要逐字抄写。只输出一个 JSON 对象：
        {"activity": "一句话描述", "kind": "work 或 study、leisure、communication、other"}
        """
    }

    /// The title of the front window of the app with `pid` (readable with the screen recording permission).
    private static func windowTitle(pid: pid_t) -> String? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for w in windows where (w[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == pid && (w[kCGWindowLayer as String] as? Int) == 0 {
            if let name = w[kCGWindowName as String] as? String, !name.isEmpty { return name }
        }
        return nil
    }

    /// The display the pointer is on.
    private static func displayUnderPointer() -> CGDirectDisplayID? {
        let point = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        return (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    struct CaptureError: LocalizedError {
        var errorDescription: String?
    }

    /// A JPEG of `display` (or the first display) without the pet's own windows, its longest side at most
    /// `ScreenGlances.maxSide` pixels.
    @MainActor
    private static func capture(display id: CGDirectDisplayID?) async throws -> Data {
        if let path = testImage {
            guard let data = FileManager.default.contents(atPath: path) else { throw CaptureError(errorDescription: "DESKPET_SCREENSHOT") }
            return data
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == id }) ?? content.displays.first else {
            throw CaptureError(errorDescription: tr("没有找到显示器。", "No display found."))
        }
        let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        let config = SCStreamConfiguration()
        let size = ScreenGlances.size(width: display.width * 2, height: display.height * 2)
        config.width = size.width
        config.height = size.height
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        guard let jpeg = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.6]) else {
            throw CaptureError(errorDescription: tr("截图无法编码。", "The screenshot could not be encoded."))
        }
        return jpeg
    }
}
