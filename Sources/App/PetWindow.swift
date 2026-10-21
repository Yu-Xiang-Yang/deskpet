import AppKit
import QuartzCore
import WebKit

@MainActor
protocol PetWindowDelegate: AnyObject {
    func petDidBecomeReady(mode: String)
    func petDidClick(area: String, clickCount: Int)
    func petContextMenu() -> NSMenu
    func petDidMove()
    /// The owner let go of the pet after dragging it.
    func petDidDrop()
    func petAnswersCleared()
}

/// Borderless, transparent, non-activating panel that floats above other windows.
final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Transparent view above the web view: receives every mouse event, so the web content only renders.
final class PetInteractionView: NSView {
    weak var owner: PetWindowController?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { owner?.mouseDown(event) }
    override func mouseDragged(with event: NSEvent) { owner?.mouseDragged(event) }
    override func mouseUp(with event: NSEvent) { owner?.mouseUp(event) }
    override func rightMouseDown(with event: NSEvent) { owner?.rightMouseDown(event, in: self) }
    /// Scrolls the bubble under the pointer (long research answers).
    override func scrollWheel(with event: NSEvent) { owner?.scrollWheel(event) }
}

final class PetWindowController: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    /// Size of the pet page at scale 1: a bubble area above a 320×340 character.
    static let baseSize = NSSize(width: 320, height: 560)
    static let stageHeight: CGFloat = 340
    /// Bubble area for small talk, and the larger one for research answers.
    static let chatBubbles = NSSize(width: 304, height: 214)
    static let researchBubbles = NSSize(width: 420, height: 380)

    private(set) var bubbles = PetWindowController.chatBubbles

    weak var delegate: PetWindowDelegate?
    let panel: PetPanel
    private(set) var webView: WKWebView!
    private let overlay = PetInteractionView()

    private var ready = false
    private var pending: [() -> Void] = []
    private var model: PetModel?

    // Click-through mask in CSS pixels, reported by pet.js.
    private var mask: [Bool] = []
    private var maskCols = 0, maskRows = 0, maskCell: CGFloat = 10

    private var trackTimer: Timer?
    private var lastMouse = NSPoint(x: -1, y: -1)

    private var dragStartMouse: NSPoint?
    private var dragStartOrigin = NSPoint.zero
    /// Bubbles below the character instead of above it (near the top of the screen, where there is no room).
    private(set) var flipped = UserDefaults.standard.bool(forKey: "petBubblesBelow")
    private(set) var dragging = false

    var scale: CGFloat = 1 {
        didSet { applyScale() }
    }

    override init() {
        panel = PetPanel(contentRect: NSRect(origin: .zero, size: Self.baseSize),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        webView = WKWebView.make(handlerName: "pet", handler: self)
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear

        let container = NSView(frame: NSRect(origin: .zero, size: Self.baseSize))
        container.autoresizesSubviews = true
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        overlay.frame = container.bounds
        overlay.autoresizingMask = [.width, .height]
        overlay.owner = self
        container.addSubview(webView)
        container.addSubview(overlay)
        panel.contentView = container
    }

    // MARK: Lifecycle

    func show(model: PetModel?, scale: CGFloat) {
        self.model = model
        self.scale = scale
        restorePosition()
        panel.orderFrontRegardless()
        reload()
        startTracking()
    }

    func reload() {
        ready = false
        mask = []
        webView.load(URLRequest(url: AppSchemeHandler.url("web/pet.html")))
    }

    func reload(model newModel: PetModel?) {
        model = newModel
        reload()
    }

    func setLayer(_ layer: PetLayer) {
        switch layer {
        case .top: panel.level = .floating
        case .normal: panel.level = .normal
        // Just above the desktop icons: covered by every app window, visible when the desktop is.
        case .desktop: panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        }
        if panel.isVisible { panel.orderFrontRegardless() }
    }

    private func restorePosition() {
        // The saved frame ends with the frame of its screen; when that display is gone, AppKit would only
        // nudge the window onto another screen, somewhere in mid-air.
        let saved = UserDefaults.standard.string(forKey: "NSWindow Frame DeskPetPanel")?
            .split(separator: " ").compactMap { Double($0) } ?? []
        let screenPresent = saved.count >= 8 && NSScreen.screens.contains {
            abs($0.frame.minX - saved[4]) < 1 && abs($0.frame.minY - saved[5]) < 1 && abs($0.frame.width - saved[6]) < 1
        }
        panel.setFrameAutosaveName("DeskPetPanel")  // also applies the saved frame, if any
        if screenPresent {
            // AppKit rescales a saved frame when the visible area of its screen changed (for example the menu bar
            // moved to another display) and may then put it on another screen: the saved position is used as is.
            let size = scaledSize
            let x = saved[0] + (saved[2] - size.width) / 2
            place(NSPoint(x: x, y: saved[1] + (flipped ? bubbleBand : 0)), size: size)
            if ready { webView.call("pet.setScale", .number(Double(scale))) }
        } else {
            moveToMainScreen()
        }
        bringBackIfOffScreen()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.bringBackIfOffScreen() }
        }
    }

    /// The bottom-right corner of the main screen.
    private func moveToMainScreen() {
        guard let area = (NSScreen.screens.first ?? NSScreen.main)?.visibleFrame else { return }
        place(NSPoint(x: area.maxX - scaledSize.width - 24, y: area.minY))
    }

    /// After a display was disconnected (or on launch, when the saved position is on a display that is gone),
    /// a pet whose body is on no screen comes back to the main screen.
    func bringBackIfOffScreen() {
        let f = panel.frame
        let body = NSRect(x: f.midX - f.width * 0.2, y: characterOrigin.y, width: f.width * 0.4, height: characterHeight * 0.6)
        guard !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(body) }) else { return }
        cancelHop()
        moveToMainScreen()
        panel.saveFrame(usingName: "DeskPetPanel")
    }

    /// Only the character scales; the bubble area keeps its size so the text stays readable.
    private var scaledSize: NSSize {
        NSSize(width: max(Self.baseSize.width, (Self.baseSize.width * scale).rounded(), bubbles.width + 16),
               height: (bubbles.height + 6 + Self.stageHeight * scale).rounded())
    }

    /// Switches between the small-talk and the research bubble area; the window grows upwards.
    func setBubbles(_ size: NSSize) {
        guard size != bubbles else { return }
        bubbles = size
        applyScale()
        whenReady { [weak self] in self?.webView.call("pet.setLayout", .number(Double(size.width)), .number(Double(size.height))) }
    }

    /// Resizes around the bottom centre, so the character's feet stay where they were.
    private func applyScale() {
        let size = scaledSize
        var origin = characterOrigin
        origin.x += (panel.frame.width - size.width) / 2
        place(origin, size: size)
        if ready { webView.call("pet.setScale", .number(Double(scale))) }
    }

    // MARK: Placement
    // The window is the character plus a band for the bubbles, normally above the character. Positions are
    // expressed as the character's origin: the window's left edge and the character's feet.

    private var bubbleBand: CGFloat { bubbles.height + 6 }
    var characterHeight: CGFloat { scaledSize.height - bubbleBand }
    /// Points between the bottom of the stage and the character's paws (transparent margin of the model).
    private(set) var feetGap: CGFloat = 0
    /// Width of the drawn character stage (the body itself is about half of it).
    var stageWidth: CGFloat { Self.baseSize.width * scale }

    /// The window's left edge and the character's feet, in screen coordinates.
    var characterOrigin: NSPoint {
        NSPoint(x: panel.frame.minX, y: panel.frame.minY + (flipped ? bubbleBand : 0))
    }

    /// Moves the character to `origin`, kept on screen: its sides may reach the screen edges, its head the menu
    /// bar and its feet a little into the Dock. The bubbles go below the character when there is no room above.
    private func place(_ origin: NSPoint, size: NSSize? = nil) {
        let size = size ?? scaledSize
        let charHeight = size.height - bubbleBand
        let probe = NSPoint(x: origin.x + size.width / 2, y: origin.y + charHeight / 2)
        let screen = NSScreen.screens.first { $0.frame.contains(probe) } ?? panel.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let area = screen.frame, visible = screen.visibleFrame
        // The window is wider than the character: up to the middle of it (less a quarter of the drawn stage)
        // may overhang the edge, so that the character itself reaches it.
        let overhang = max(0, size.width / 2 - Self.baseSize.width * scale * 0.25)
        var o = origin
        o.x = min(max(o.x, area.minX - overhang), area.maxX - size.width + overhang)
        o.y = min(max(o.y, area.minY - charHeight * 0.05), visible.maxY - charHeight)
        let below = o.y + charHeight + bubbleBand > visible.maxY
        if below != flipped {
            flipped = below
            UserDefaults.standard.set(below, forKey: "petBubblesBelow")
            if ready { webView.call("pet.setBubblesBelow", .bool(below)) }
        }
        panel.setFrame(NSRect(x: o.x, y: o.y - (below ? bubbleBand : 0), width: size.width, height: size.height), display: true)
    }

    // MARK: JavaScript API

    private func whenReady(_ action: @escaping () -> Void) {
        if ready { action() } else { pending.append(action) }
    }

    /// Adds a bubble to the stack above the pet; `fromUser` shows the user's own words.
    func say(_ text: String, kind: String = "", ms: Int? = nil, fromUser: Bool = false) {
        whenReady { [weak self] in
            var opts: [String: JSON] = ["kind": .string(kind), "from": fromUser ? "user" : "pet"]
            if let ms { opts["ms"] = .number(Double(ms)) }
            self?.webView.call("pet.say", .string(text), .object(opts))
        }
    }

    func play(_ motion: PetMotion) {
        whenReady { [weak self] in self?.webView.call("pet.play", .string(motion.rawValue)) }
    }

    /// A cat sound (only for characters with "voice": "cat" in their pet-map.json); `chance` 0…1.
    func meow(_ kind: MeowKind, chance: Double = 1) {
        let settings = AppSettings.shared
        guard settings.meow, settings.meowVolume > 0, Double.random(in: 0..<1) < chance else { return }
        whenReady { [weak self] in
            self?.webView.call("pet.meow", .string(kind.rawValue), .number(settings.meowVolume))
        }
    }

    func setStatus(_ text: String?) {
        whenReady { [weak self] in self?.webView.call("pet.setStatus", text.map(JSON.string) ?? .null) }
    }

    func setResearch(_ on: Bool) {
        whenReady { [weak self] in self?.webView.call("pet.setResearch", .bool(on)) }
    }

    func beginAnswer(_ id: UUID) {
        whenReady { [weak self] in self?.webView.call("pet.beginAnswer", .string(id.uuidString)) }
    }

    func answerDelta(_ id: UUID, _ text: String) {
        whenReady { [weak self] in self?.webView.call("pet.answerDelta", .string(id.uuidString), .string(text)) }
    }

    func finishAnswer(_ id: UUID, _ text: String, conversationID: String) {
        whenReady { [weak self] in
            self?.webView.call("pet.finishAnswer", .string(id.uuidString), .string(text), .string(conversationID))
        }
    }

    func failAnswer(_ id: UUID) {
        whenReady { [weak self] in self?.webView.call("pet.failAnswer", .string(id.uuidString)) }
    }

    func setGrooving(_ on: Bool) {
        whenReady { [weak self] in self?.webView.call("pet.setGrooving", .bool(on)) }
    }

    func beat(_ strength: Double) {
        guard ready else { return }
        webView.call("pet.beat", .number(strength))
    }

    func setSleeping(_ on: Bool) {
        whenReady { [weak self] in self?.webView.call("pet.setSleeping", .bool(on)) }
    }

    // MARK: WKScriptMessageHandler

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            ready = true
            let actions = pending
            pending = []
            actions.forEach { $0() }
            delegate?.petDidBecomeReady(mode: body["mode"] as? String ?? "svg")
        case "mask":
            guard let bits = body["bits"] as? String else { return }
            maskCols = body["cols"] as? Int ?? 0
            maskRows = body["rows"] as? Int ?? 0
            maskCell = CGFloat(body["cell"] as? Int ?? 10)
            mask = bits.map { $0 == "1" }
        case "feet":
            feetGap = CGFloat(body["gap"] as? Double ?? Double(body["gap"] as? Int ?? 0))
        case "answersCleared":
            delegate?.petAnswersCleared()
        case "log":
            NSLog("[pet.js] %@", body["text"] as? String ?? "")
        default:
            break
        }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        var config: [String: JSON] = ["scale": .number(Double(scale)), "below": .bool(flipped),
                                      "layout": [.number(Double(bubbles.width)), .number(Double(bubbles.height))],
                                      "strings": ["more": .string(tr("点击查看完整内容 · 可滚动", "Click for the full answer · scrollable"))]]
        if !PetModel.cubismCoreInstalled {
            config["missing"] = .string(tr("没有找到 Live2D Cubism Core（live2dcubismcore.min.js）。", "Live2D Cubism Core (live2dcubismcore.min.js) is missing."))
        } else if let model {
            config["model"] = .string(model.modelURL.absoluteString)
            if let map = model.map { config["map"] = map }
        }
        webView.call("pet.init", .object(config))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        reload()
    }

    // MARK: Click-through and gaze

    private func startTracking() {
        trackTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.track() }
        RunLoop.main.add(timer, forMode: .common)
        trackTimer = timer
    }

    /// CSS-pixel point (origin top-left) for a screen point.
    private func pagePoint(_ screen: NSPoint) -> NSPoint {
        let frame = panel.frame
        return NSPoint(x: screen.x - frame.minX, y: frame.maxY - screen.y)
    }

    private func isSolid(_ p: NSPoint) -> Bool {
        guard maskCols > 0, p.x >= 0, p.y >= 0 else { return false }
        let c = Int(p.x / maskCell), r = Int(p.y / maskCell)
        guard c < maskCols, r < maskRows else { return false }
        let i = r * maskCols + c
        return i < mask.count && mask[i]
    }

    private func track() {
        guard panel.isVisible else { return }
        let mouse = NSEvent.mouseLocation
        if !dragging {
            let solid = panel.frame.contains(mouse) && isSolid(pagePoint(mouse))
            if panel.ignoresMouseEvents == solid { panel.ignoresMouseEvents = !solid }
        }
        updateSafeArea()
        if mouse != lastMouse, ready {
            lastMouse = mouse
            let p = pagePoint(mouse)
            webView.call("pet.lookAt", .number(Double(p.x)), .number(Double(p.y)))
        }
    }

    /// Tells the page which horizontal part of the window is on screen, so that bubbles stay visible
    /// when the window overhangs a screen edge (only sent when it changes).
    private var lastSafeArea = NSPoint(x: -1, y: -1)

    private func updateSafeArea() {
        guard ready, let screen = panel.screen ?? NSScreen.main else { return }
        let f = panel.frame, visible = screen.visibleFrame
        let range = NSPoint(x: max(0, visible.minX - f.minX).rounded(), y: min(f.width, visible.maxX - f.minX).rounded())
        guard range != lastSafeArea else { return }
        lastSafeArea = range
        webView.call("pet.setSafeArea", .number(Double(range.x)), .number(Double(range.y)))
    }

    // MARK: Hopping

    private(set) var hopping = false
    private var hopTimer: Timer?

    /// Moves the pet horizontally to window origin `targetX` in a series of hops along its current baseline.
    func wander(to targetX: CGFloat, completion: (() -> Void)? = nil) {
        guard !hopping, !dragging, ready else { return }
        let start = panel.frame.origin
        let distance = targetX - start.x
        guard abs(distance) > 4 else { return }
        let count = max(1, Int(ceil(abs(distance) / 170)))
        hopping = true
        hop(remaining: count, step: distance / CGFloat(count), baseY: start.y, completion: completion)
    }

    /// A single jump on the spot (from excitement).
    func bounce() {
        guard !hopping, !dragging, ready else { return }
        hopping = true
        hop(remaining: 1, step: 0, baseY: panel.frame.origin.y, completion: nil)
    }

    /// One hop: crouch, fly along a parabola, land with a squash, then the next hop.
    private func hop(remaining: Int, step: CGFloat, baseY: CGFloat, completion: (() -> Void)?) {
        guard remaining > 0, hopping else {
            hopping = false
            panel.saveFrame(usingName: "DeskPetPanel")
            completion?()
            return
        }
        webView.call("pet.hop", "crouch")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.17) { [weak self] in
            guard let self, self.hopping else { return }
            self.webView.call("pet.hop", "air")
            let from = self.panel.frame.origin.x
            let height = (step == 0 ? 46 : 34 + abs(step) * 0.22) * max(self.scale, 0.5)
            let duration = 0.36 + Double(abs(step)) / 900
            let begin = CACurrentMediaTime()
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] t in
                guard let self, self.hopping else { t.invalidate(); return }
                let p = min(1, (CACurrentMediaTime() - begin) / duration)
                let x = from + step * CGFloat(p)
                let y = baseY + height * CGFloat(4 * p * (1 - p))
                self.panel.setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
                guard p >= 1 else { return }
                t.invalidate()
                self.webView.call("pet.hop", "land")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) {
                    self.hop(remaining: remaining - 1, step: step, baseY: baseY, completion: completion)
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.hopTimer = timer
        }
    }

    /// Jumps along an arc so that the character's origin (window left, feet) lands on `target`: up onto a
    /// window, down to the floor or across to another window.
    func leap(to target: NSPoint, completion: (() -> Void)? = nil) {
        guard !hopping, !dragging, ready else { return }
        hopping = true
        let start = characterOrigin
        let dx = target.x - start.x, dy = target.y - start.y
        let band = flipped ? bubbles.height + 6 : 0
        // Upwards the arc rises above the target; downwards it is a small hop and then a drop.
        let height = (dy > 0 ? dy * 0.3 + 46 : 40) * max(scale, 0.5)
        let duration = 0.42 + Double(hypot(dx, dy)) / 1500
        webView.call("pet.hop", "crouch")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.hopping else { return }
            self.webView.call("pet.hop", "air")
            let begin = CACurrentMediaTime()
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] t in
                guard let self, self.hopping else { t.invalidate(); return }
                let p = CGFloat(min(1, (CACurrentMediaTime() - begin) / duration))
                let x = start.x + dx * p
                let y = start.y + dy * p + height * 4 * p * (1 - p)
                self.panel.setFrameOrigin(NSPoint(x: x.rounded(), y: (y - band).rounded()))
                guard p >= 1 else { return }
                t.invalidate()
                self.land(at: target, completion: completion)
            }
            RunLoop.main.add(timer, forMode: .common)
            self.hopTimer = timer
        }
    }

    /// Falls straight down (accelerating) until the feet reach `floorY`, e.g. when the window below went away.
    func fall(to floorY: CGFloat, completion: (() -> Void)? = nil) {
        guard !dragging, ready else { return }
        cancelHop()
        hopping = true
        let start = characterOrigin
        let band = flipped ? bubbles.height + 6 : 0
        let gravity: CGFloat = 2600  // pt/s²
        let begin = CACurrentMediaTime()
        webView.call("pet.hop", "air")
        webView.call("pet.play", "surprised")
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] t in
            guard let self, self.hopping else { t.invalidate(); return }
            let elapsed = CGFloat(CACurrentMediaTime() - begin)
            let y = max(floorY, start.y - gravity * elapsed * elapsed / 2)
            self.panel.setFrameOrigin(NSPoint(x: start.x.rounded(), y: (y - band).rounded()))
            guard y <= floorY else { return }
            t.invalidate()
            self.land(at: NSPoint(x: start.x, y: floorY), completion: completion)
        }
        RunLoop.main.add(timer, forMode: .common)
        hopTimer = timer
    }

    private func land(at origin: NSPoint, completion: (() -> Void)?) {
        webView.call("pet.hop", "land")
        place(origin)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) { [weak self] in
            guard let self, self.hopping else { return }
            self.hopping = false
            self.panel.saveFrame(usingName: "DeskPetPanel")
            completion?()
        }
    }

    /// Moves the character without animation (riding on a window that is being moved).
    func shift(to origin: NSPoint) {
        guard !hopping, !dragging else { return }
        place(origin)
    }

    func cancelHop() {
        guard hopping else { return }
        hopping = false
        hopTimer?.invalidate()
        webView.call("pet.hop", "")
    }

    // MARK: Mouse

    func mouseDown(_ event: NSEvent) {
        cancelHop()
        dragStartMouse = NSEvent.mouseLocation
        dragStartOrigin = characterOrigin
        dragging = false
    }

    func mouseDragged(_ event: NSEvent) {
        guard let start = dragStartMouse else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - start.x, dy = now.y - start.y
        if !dragging {
            guard hypot(dx, dy) > 3 else { return }
            dragging = true
            webView.call("pet.setDragging", .bool(true))
        }
        place(NSPoint(x: dragStartOrigin.x + dx, y: dragStartOrigin.y + dy))
        delegate?.petDidMove()
    }

    func mouseUp(_ event: NSEvent) {
        defer { dragStartMouse = nil }
        if dragging {
            dragging = false
            webView.call("pet.setDragging", .bool(false))
            panel.saveFrame(usingName: "DeskPetPanel")
            delegate?.petDidDrop()
            return
        }
        let p = pagePoint(NSEvent.mouseLocation)
        let clicks = event.clickCount
        webView.evaluateJavaScript("pet.hitArea(\(Double(p.x)), \(Double(p.y)))") { [weak self] result, _ in
            if let area = result as? String { self?.delegate?.petDidClick(area: area, clickCount: clicks) }
        }
    }

    func scrollWheel(_ event: NSEvent) {
        // Precise deltas (trackpads, Magic Mouse) are pixels; wheel notches are lines.
        let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 16
        guard dy != 0 else { return }
        let p = pagePoint(NSEvent.mouseLocation)
        webView.call("pet.scrollAt", .number(Double(p.x)), .number(Double(p.y)), .number(Double(dy)))
    }

    func rightMouseDown(_ event: NSEvent, in view: NSView) {
        guard let menu = delegate?.petContextMenu() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }
}
