import AppKit
import QuartzCore
import WebKit

@MainActor
protocol PetWindowDelegate: AnyObject {
    func petDidBecomeReady(mode: String)
    func petDidClick(area: String, clickCount: Int)
    func petContextMenu() -> NSMenu
    func petDidMove()
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

    func setLevel(alwaysOnTop: Bool) {
        panel.level = alwaysOnTop ? .floating : .normal
    }

    private func restorePosition() {
        if !panel.setFrameUsingName("DeskPetPanel"), let area = NSScreen.main?.visibleFrame {
            let size = scaledSize
            panel.setFrame(NSRect(x: area.maxX - size.width - 24, y: area.minY, width: size.width, height: size.height), display: false)
        }
        panel.setFrameAutosaveName("DeskPetPanel")
        applyScale()
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
        var frame = panel.frame
        frame.origin.x += (frame.width - size.width) / 2
        frame.size = size
        panel.setFrame(clamp(frame), display: true)
        if ready { webView.call("pet.setScale", .number(Double(scale))) }
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
        var config: [String: JSON] = ["scale": .number(Double(scale)),
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
        if mouse != lastMouse, ready {
            lastMouse = mouse
            let p = pagePoint(mouse)
            webView.call("pet.lookAt", .number(Double(p.x)), .number(Double(p.y)))
        }
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
            let height = (34 + abs(step) * 0.22) * max(self.scale, 0.5)
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
        dragStartOrigin = panel.frame.origin
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
        var frame = panel.frame
        frame.origin = NSPoint(x: dragStartOrigin.x + dx, y: dragStartOrigin.y + dy)
        panel.setFrame(clamp(frame), display: true)
        delegate?.petDidMove()
    }

    func mouseUp(_ event: NSEvent) {
        defer { dragStartMouse = nil }
        if dragging {
            dragging = false
            webView.call("pet.setDragging", .bool(false))
            panel.saveFrame(usingName: "DeskPetPanel")
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

    /// Keeps at least the character's body on a screen; the feet may overlap the Dock.
    private func clamp(_ frame: NSRect) -> NSRect {
        let center = NSPoint(x: frame.midX, y: frame.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main ?? NSScreen.screens[0]
        let area = screen.frame
        let visible = screen.visibleFrame
        var f = frame
        // With the wide research bubbles the whole window stays on screen; otherwise the transparent
        // margins beside the character may overhang the edge.
        let marginX = bubbles.width > Self.chatBubbles.width ? 0 : f.width * 0.3
        f.origin.x = min(max(f.origin.x, area.minX - marginX), area.maxX - f.width + marginX)
        f.origin.y = min(max(f.origin.y, area.minY - f.height * 0.05), visible.maxY - f.height * 0.45)
        return f
    }
}
