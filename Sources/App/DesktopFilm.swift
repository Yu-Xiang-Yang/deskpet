import AppKit
import WebKit

/// The desktop film: a live wallpaper filling the screen where the pet lives, just above the system wallpaper and
/// below the desktop icons and widgets (web/film.html). The character plays in it as in a film: grain, light that
/// follows the time of day, a camera that moves and cuts, subtitles for its words, intertitles for reminders. It
/// stands where no widget or window hides it, and walks off from under one that arrives.
///
/// The film plays while the desktop is in view, that is while other apps' windows cover at most a fifth of the
/// screen (DesktopView); the floating pet then steps into it (`onLiveChange`), and steps back out when windows cover
/// the desktop again, leaving the still set as the wallpaper.
///
/// The window lies below the desktop icons, so it receives no mouse events: the pointer is followed by polling, and
/// clicks on the empty desktop are seen through a global event monitor (mouse events need no permission).
@MainActor
final class DesktopFilm: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    /// Seconds between looks at the windows on the film's screen.
    static let pollInterval: TimeInterval = 0.35
    /// After this long without the film, the next showing opens in full: from black, the camera pulling back.
    static let fullOpeningAfter: TimeInterval = 20 * 60

    private var window: NSWindow?
    private var webView: WKWebView?
    private var ready = false
    private var pending: [() -> Void] = []
    private var model: PetModel?
    private var tracker = DesktopViewTracker()
    private var pollTimer: Timer?
    private var pointerTimer: Timer?
    private var clickMonitor: Any?
    /// Catches clicks on the character (CatcherPanel) while the pointer is on it.
    private var catcher: CatcherPanel?
    /// The pet's menu is open from the catcher: the catcher stays where it is, or the menu would move along with it.
    private var menuShowing = false
    private var followTicks = 0
    /// Left and right clicks the catcher took, for test runs.
    private(set) var caught = (left: 0, right: 0)
    private var screenObserver: NSObjectProtocol?
    private var lastPointer = NSPoint(x: -1, y: -1)
    private var lastLayout: JSON?
    /// Other apps' windows on the film's screen while it plays (the character keeps clear of them too).
    private var openWindows: [NSRect] = []
    /// The desktop icons (their pictures, screen coordinates), when Finder has told where they are (IconVisits).
    var icons: [(name: String, frame: NSRect)] = [] { didSet { place() } }
    /// When the film last stopped playing.
    private var lastShowing: Date?
    /// Where the chat box goes, below the subtitles (CSS pixels from the top left), as the page reports it.
    private var subtitlePoint: NSPoint?

    private(set) var isLive = false
    /// Tests: plays (true) or stays still (false) whatever the desktop shows; nil follows the desktop.
    var forced: Bool? { didSet { poll() } }

    /// Whether the film may play now (owner present, pet shown, no research answers, …).
    var canPlay: () -> Bool = { true }
    /// The screen the pet lives on.
    var screenForPet: () -> NSScreen? = { NSScreen.main }
    /// Whether the menu bar draws light text (over a dark picture); nil when unknown.
    var menuBarIsDark: () -> Bool? = { nil }
    var onLiveChange: ((Bool) -> Void)?
    /// A click on the character while the film plays: "head" or "body".
    var onClick: ((String) -> Void)?
    /// A right click on the character: the pet's context menu, for the event in the view.
    var onContextMenu: ((NSEvent, NSView) -> Void)?
    /// The opening is over (`true` after a full opening); the greeting may follow.
    var onOpened: ((Bool) -> Void)?
    /// The character got to a desktop icon or widget ("icon" or "widget", its name, the widget's owner, whether
    /// the icon is a file just put on the desktop): the remark is for the native side to say.
    var onVisit: ((_ kind: String, _ name: String, _ owner: String, _ arrived: Bool) -> Void)?

    var isEnabled: Bool { window != nil }

    /// Centre of the chat box while the film plays: at the foot of the picture, below the subtitles.
    var chatPoint: (NSPoint, NSScreen)? {
        guard let window, let screen = window.screen else { return nil }
        let f = window.frame, p = subtitlePoint ?? NSPoint(x: f.width / 2, y: f.height - 34)
        return (NSPoint(x: f.minX + p.x, y: f.maxY - p.y), screen)
    }

    // MARK: Window

    func setEnabled(_ on: Bool, model: PetModel?) {
        guard on != isEnabled else { return }
        if on { open(model) } else { close() }
    }

    private func open(_ model: PetModel?) {
        self.model = model
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
        // Just above the system wallpaper, below the desktop icons and widgets.
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        w.ignoresMouseEvents = true
        w.isReleasedWhenClosed = false
        w.hasShadow = false
        w.isOpaque = true
        w.backgroundColor = .black
        w.animationBehavior = .none
        let web = WKWebView.make(handlerName: "pet", handler: self)
        // Below every other window this one often counts as occluded, and WebKit would freeze the page; the page
        // pauses itself whenever the desktop is covered (private but long-standing WebKit switch, if available).
        let occlusion = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        if web.responds(to: occlusion) { web.perform(occlusion, with: nil) }  // nil = NO
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")
        web.autoresizingMask = [.width, .height]
        w.contentView = web
        window = w
        webView = web
        place()
        w.orderFrontRegardless()
        load()
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        }
    }

    private func close() {
        if isLive { setLive(false) }  // the pet steps back out
        tracker.reset()
        pollTimer?.invalidate()
        pollTimer = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "pet")
        window?.orderOut(nil)
        window = nil
        webView = nil
        ready = false
        pending = []
        lastLayout = nil
        openWindows = []
    }

    func reload(model: PetModel?) {
        self.model = model
        if isEnabled { load() }
    }

    private func load() {
        ready = false
        pending = []
        lastLayout = nil
        // A reload during a showing (another character, a crashed web process) picks the showing up again.
        if isLive { whenReady { [weak self] in self?.webView?.call("film.setLive", .bool(true), .object(["long": .bool(false)])) } }
        webView?.load(URLRequest(url: AppSchemeHandler.url("web/film.html")))
    }

    /// Covers the pet's screen; tells the page where the menu bar and the Dock are, and what lies above the film:
    /// the desktop widgets (with their owners and names), the other apps' windows while the film plays, the desktop
    /// icons (the character keeps clear of them, and visits the icons and widgets now and then).
    private func place(widgets: [Widget]? = nil) {
        guard let window, let screen = screenForPet() ?? NSScreen.main ?? NSScreen.screens.first else { return }
        if window.frame != screen.frame { window.setFrame(screen.frame, display: true) }
        let f = screen.frame, v = screen.visibleFrame
        func box(_ r: NSRect) -> [String: JSON] {
            ["x": .number(Double(r.minX - f.minX)), "y": .number(Double(f.maxY - r.maxY)), "w": .number(Double(r.width)), "h": .number(Double(r.height))]
        }
        let widgetBoxes: [JSON] = (widgets ?? Self.windows().widgets).filter { $0.frame.intersects(f) }.map {
            .object(box($0.frame).merging(["owner": .string($0.owner), "name": .string($0.name)]) { a, _ in a })
        }
        let windowBoxes: [JSON] = openWindows.filter { $0.intersects(f) }.map { r in
            [.number(Double(r.minX - f.minX)), .number(Double(f.maxY - r.maxY)), .number(Double(r.width)), .number(Double(r.height))]
        }
        let mainScreen = screen == NSScreen.screens.first
        let iconBoxes: [JSON] = mainScreen ? icons.filter { $0.frame.intersects(f) }.map {
            .object(box($0.frame).merging(["name": .string($0.name)]) { a, _ in a })
        } : []
        var layout: [String: JSON] = [
            "top": .number(Double(max(0, f.maxY - v.maxY))), "bottom": .number(Double(max(0, v.minY - f.minY))),
            "left": .number(Double(max(0, v.minX - f.minX))), "right": .number(Double(max(0, f.maxX - v.maxX))),
            "widgets": .array(widgetBoxes), "windows": .array(windowBoxes), "icons": .array(iconBoxes),
            // Finder draws the desktop icons on the main screen only, from its right edge; where they are is known
            // only while icon play is on (Finder is asked).
            "iconColumn": .bool(mainScreen && icons.isEmpty),
        ]
        if let dark = menuBarIsDark() { layout["menuBarDark"] = .bool(dark) }
        let json = JSON.object(layout)
        guard json != lastLayout, ready else { return }
        lastLayout = json
        webView?.call("film.setLayout", json)
    }

    // MARK: Desktop in view

    private func poll() {
        guard let window else { return }
        let found = Self.windows()
        let live: Bool
        if let forced {
            live = forced
        } else {
            let coverage = DesktopView.coverage(of: window.frame, by: found.others)
            live = tracker.update(coverage: coverage, allowed: canPlay())
        }
        // The layout first, so that a showing starts with the character clear of the windows left open.
        openWindows = live ? found.others : []
        place(widgets: found.widgets)
        if live != isLive { setLive(live) }
    }

    /// A desktop widget: its frame (screen coordinates), the app that shows it ("通知中心" for the system's own
    /// widgets), and its title where the system tells it.
    struct Widget: Equatable {
        var frame: NSRect
        var owner: String
        var name: String
    }

    /// Other apps' normal windows on the current Space, and the desktop widgets (windows between the wallpaper and
    /// the desktop icons, such as Notification Center's widgets), in screen (Cocoa) coordinates. Window bounds and
    /// owners need no screen-recording permission (titles of other apps' windows do; without it they are empty).
    static func windows() -> (others: [NSRect], widgets: [Widget]) {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return ([], []) }
        let own = ProcessInfo.processInfo.processIdentifier
        let flipY = NSScreen.screens.first?.frame.maxY ?? 0  // window bounds start at the top left of the main screen
        let desktop = Int(CGWindowLevelForKey(.desktopWindow))
        var others: [NSRect] = [], widgets: [Widget] = []
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int,
                  (info[kCGWindowOwnerPID as String] as? pid_t) != own,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.1,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let b = CGRect(dictionaryRepresentation: dict), b.width >= 40, b.height >= 40 else { continue }
            let rect = NSRect(x: b.minX, y: flipY - b.maxY, width: b.width, height: b.height)
            if layer == 0 {
                others.append(rect)
            } else if layer > desktop, layer < desktop + 100 {
                // Not the full-screen desktop windows (Finder's icons, the window server's backdrops).
                let owner = info[kCGWindowOwnerName as String] as? String ?? ""
                let fullScreen = NSScreen.screens.contains { rect.width >= $0.frame.width * 0.9 }
                if owner != "Window Server", !fullScreen {
                    widgets.append(Widget(frame: rect, owner: owner, name: info[kCGWindowName as String] as? String ?? ""))
                }
            }
        }
        return (others, widgets)
    }

    /// Stops the film at once, when the pet is needed in its own window; it plays again once allowed and the
    /// desktop is still in view.
    func interrupt() {
        tracker.reset()
        if isLive, forced == nil { setLive(false) }
    }

    private func setLive(_ on: Bool) {
        isLive = on
        NSLog("DeskPet film: %@", on ? "playing" : "still")
        var options: [String: JSON] = [:]
        if on {
            options["long"] = .bool(lastShowing.map { Date().timeIntervalSince($0) > Self.fullOpeningAfter } ?? true)
            startFollowing()
        } else {
            lastShowing = Date()
            stopFollowing()
        }
        whenReady { [weak self] in self?.webView?.call("film.setLive", .bool(on), .object(options)) }
        onLiveChange?(on)
    }

    // MARK: Pointer and clicks

    private func startFollowing() {
        pointerTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.followPointer() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pointerTimer = timer
        lastPointer = NSPoint(x: -1, y: -1)
        if clickMonitor == nil {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
                MainActor.assumeIsolated { self?.clicked(at: NSEvent.mouseLocation) }
            }
        }
    }

    private func stopFollowing() {
        pointerTimer?.invalidate()
        pointerTimer = nil
        catcher?.orderOut(nil)
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    /// CSS-pixel point (origin top-left) for a screen point.
    private func pagePoint(_ p: NSPoint) -> NSPoint {
        guard let f = window?.frame else { return p }
        return NSPoint(x: p.x - f.minX, y: f.maxY - p.y)
    }

    /// The character goes to the icon of a file just put on the desktop (or looks at it from where it is), then
    /// remarks on it (`onVisit`).
    func visitIcon(_ name: String, arrived: Bool) {
        guard isLive, ready, let webView else { return }
        webView.call("film.visit", .object(["name": .string(name), "arrived": .bool(arrived)]))
    }

    private func followPointer() {
        guard ready, let window, let webView else { return }
        let mouse = NSEvent.mouseLocation
        followTicks += 1
        // A still pointer: the character may walk away from under it, so the catcher is checked twice a second.
        guard mouse != lastPointer || (catcher?.isVisible == true && followTicks % 15 == 0) else { return }
        lastPointer = mouse
        let p = pagePoint(mouse)
        webView.call("film.pointer", .number(Double(p.x)), .number(Double(p.y)), .bool(window.frame.contains(mouse)))
        guard !menuShowing else { return }
        guard isLive, window.frame.contains(mouse) else { catcher?.orderOut(nil); return }
        webView.evaluateJavaScript("film.over(\(Double(p.x)), \(Double(p.y)))") { [weak self] result, _ in
            MainActor.assumeIsolated { self?.placeCatcher(on: result is String, at: mouse) }
        }
    }

    /// The film lies below the desktop icons and lets every click through to Finder, which would open its own menu
    /// on a right click. While the pointer is on the character, a small transparent panel just above the icons (and
    /// below every app window) follows it and takes the clicks: a right click opens the pet's menu, a left click
    /// pets it or opens the chat. Elsewhere the panel goes, so the icons stay clickable.
    private func placeCatcher(on character: Bool, at point: NSPoint) {
        guard !menuShowing, character, isLive, NSEvent.mouseLocation == point || lastPointer == point else {
            if !character { catcher?.orderOut(nil) }
            return
        }
        let panel = catcher ?? makeCatcher()
        let side: CGFloat = 56
        panel.setFrame(NSRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side), display: false)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func makeCatcher() -> CatcherPanel {
        let panel = CatcherPanel()
        panel.view.onLeftDown = { [weak self] in
            self?.caught.left += 1
            self?.clickedCharacter(at: NSEvent.mouseLocation)
        }
        panel.view.onRightDown = { [weak self] event, view in
            guard let self else { return }
            self.caught.right += 1
            // The menu tracks the pointer in a loop of its own and returns once it closes.
            self.menuShowing = true
            self.onContextMenu?(event, view)
            self.menuShowing = false
            self.lastPointer = NSPoint(x: -1, y: -1)
        }
        catcher = panel
        return panel
    }

    /// A point on the character's body in screen coordinates (the middle of the grid points on it), for test runs.
    func characterPoint(_ done: @escaping (NSPoint?) -> Void) {
        guard isLive, ready, let webView, let frame = window?.frame else { done(nil); return }
        let scan = "(() => { let sx = 0, sy = 0, n = 0; for (let y = 0; y < innerHeight; y += 16) for (let x = 0; x < innerWidth; x += 16)"
            + " if (film.over(x, y) === 'body') { sx += x; sy += y; n++; } return n ? [sx / n, sy / n] : null; })()"
        webView.evaluateJavaScript(scan) { result, _ in
            guard let xy = result as? [Double], xy.count == 2 else { done(nil); return }
            done(NSPoint(x: frame.minX + xy[0], y: frame.maxY - xy[1]))
        }
    }

    /// A left click that the catcher took: on the character it pets or opens the chat (as `clicked` for Finder's).
    private func clickedCharacter(at point: NSPoint) {
        guard isLive, ready, let webView else { return }
        let p = pagePoint(point)
        webView.evaluateJavaScript("film.click(\(Double(p.x)), \(Double(p.y)))") { [weak self] result, _ in
            guard let area = result as? String, area == "head" || area == "body" else { return }
            self?.onClick?(area)
        }
    }

    /// A click that reached the desktop (Finder) while the film plays: on the character it pets or opens the chat;
    /// elsewhere on the empty desktop the character looks there. Clicks on windows, widgets, the Dock or the menu bar
    /// do not count.
    private func clicked(at point: NSPoint) {
        guard isLive, ready, let webView, let screen = window?.screen, screen.visibleFrame.contains(point) else { return }
        let found = Self.windows()
        guard !(found.others + found.widgets.map(\.frame)).contains(where: { $0.contains(point) }) else { return }
        let p = pagePoint(point)
        webView.evaluateJavaScript("film.click(\(Double(p.x)), \(Double(p.y)))") { [weak self] result, _ in
            guard let area = result as? String, area == "head" || area == "body" else { return }
            self?.onClick?(area)
        }
    }

    // MARK: The character's page

    private func whenReady(_ action: @escaping () -> Void) {
        if ready { action() } else { pending.append(action) }
    }

    /// A call of pet.js's API (`pet.say`, `pet.play`, …), passed on by the pet's window while the film plays.
    func perform(_ fn: String, _ args: [JSON]) {
        whenReady { [weak self] in self?.webView?.call(fn, arguments: args) }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            ready = true
            place()
            let actions = pending
            pending = []
            actions.forEach { $0() }
        case "opened":
            onOpened?(body["long"] as? Bool ?? false)
        case "visit":
            onVisit?(body["kind"] as? String ?? "", body["name"] as? String ?? "", body["owner"] as? String ?? "",
                     body["arrived"] as? Bool ?? false)
        case "subtitles":
            if let x = body["x"] as? Double, let y = body["y"] as? Double { subtitlePoint = NSPoint(x: x, y: y) }
        case "log":
            NSLog("[film.js] %@", body["text"] as? String ?? "")
        default:
            break
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.call("film.init", .object(PetWindowController.characterConfig(model)))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        load()
    }
}

/// A small transparent panel just above the desktop icons, below every app window, that takes the clicks on the film's
/// character (DesktopFilm.placeCatcher). It never becomes key, so the owner's app stays active.
final class CatcherPanel: NSPanel {
    final class CatcherView: NSView {
        var onLeftDown: (() -> Void)?
        var onRightDown: ((NSEvent, NSView) -> Void)?
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control) { onRightDown?(event, self) } else { onLeftDown?() }
        }
        override func rightMouseDown(with event: NSEvent) { onRightDown?(event, self) }
        // Two-finger clicks and control-clicks arrive as these on some setups.
        override func otherMouseDown(with event: NSEvent) {}
        override func menu(for event: NSEvent) -> NSMenu? { nil }
    }

    let view = CatcherView()
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 56, height: 56), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        isOpaque = false
        hasShadow = false
        // Not quite transparent: fully clear pixels would let the clicks through.
        backgroundColor = NSColor(white: 0, alpha: 0.004)
        ignoresMouseEvents = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        contentView = view
    }
}
