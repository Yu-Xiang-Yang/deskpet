import AppKit
import CoreGraphics

/// A horizontal surface the pet can stand on, in screen (Cocoa) coordinates.
struct Ledge: Equatable {
    var minX: CGFloat
    var maxX: CGFloat
    var y: CGFloat
    /// The window whose top edge this is; nil for the floor (the bottom of the screen, above the Dock).
    var windowID: CGWindowID?

    var width: CGFloat { maxX - minX }
}

/// The visible top edges of other apps' windows. Window bounds need no screen-recording permission.
enum Ledges {
    /// Ledges on `screen`, front to back; parts of an edge hidden by windows in front are cut away, and
    /// edges too close to the menu bar for a character of `headroom` points are left out.
    static func windows(on screen: NSScreen, minWidth: CGFloat, headroom: CGFloat) -> [Ledge] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        let own = ProcessInfo.processInfo.processIdentifier
        let flipY = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY  // window bounds start at the top left
        let visible = screen.visibleFrame
        var inFront: [NSRect] = []
        var result: [Ledge] = []
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.1,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict) else { continue }
            let rect = NSRect(x: bounds.minX, y: flipY - bounds.maxY, width: bounds.width, height: bounds.height)
            let pid = info[kCGWindowOwnerPID as String] as? pid_t ?? 0
            defer { if pid != own { inFront.append(rect) } }
            guard pid != own, rect.width >= minWidth + 16, rect.height >= 120,
                  visible.contains(NSPoint(x: rect.midX, y: rect.maxY - 1)),
                  rect.maxY + headroom <= visible.maxY else { continue }
            // The edge counts where no window in front covers it.
            var parts = [(rect.minX + 8, rect.maxX - 8)]
            for cover in inFront where cover.minY < rect.maxY + 2 && cover.maxY > rect.maxY - 6 {
                parts = parts.flatMap { part -> [(CGFloat, CGFloat)] in
                    guard cover.maxX > part.0, cover.minX < part.1 else { return [part] }
                    return [(part.0, cover.minX), (cover.maxX, part.1)].filter { $0.1 > $0.0 }
                }
            }
            let id = info[kCGWindowNumber as String] as? CGWindowID
            result += parts.filter { $0.1 - $0.0 >= minWidth }.map { Ledge(minX: $0.0, maxX: $0.1, y: rect.maxY, windowID: id) }
        }
        return result
    }
}

/// Up and down: now and then the pet jumps onto the top edge of a window, walks along it, jumps across to
/// another window or back down to the floor. It rides along when the window moves and falls when the
/// window goes away (closed, minimised, covered). Only while the pet is drawn above all windows.
@MainActor
final class Climber {
    private unowned let pet: PetWindowController
    /// The window edge the pet stands on, or nil (on the floor, or wherever the owner put it).
    private(set) var ledge: Ledge?
    private var watchTimer: Timer?

    init(pet: PetWindowController) {
        self.pet = pet
    }

    private var screen: NSScreen? {
        let o = pet.characterOrigin, f = pet.panel.frame
        return NSScreen.screens.first { $0.frame.contains(NSPoint(x: o.x + f.width / 2, y: o.y + 10)) } ?? pet.panel.screen
    }

    /// Half the width of the character's body.
    private var bodyHalf: CGFloat { pet.stageWidth * 0.22 }
    private var windowHalf: CGFloat { pet.panel.frame.width / 2 }

    private func windowLedges() -> [Ledge] {
        guard let screen else { return [] }
        return Ledges.windows(on: screen, minWidth: bodyHalf * 3, headroom: pet.characterHeight + 4)
    }

    private var floorY: CGFloat { screen?.visibleFrame.minY ?? 0 }

    /// One wandering step that goes up or down. Returns false when the usual hop along the floor should happen.
    func wander() -> Bool {
        guard AppSettings.shared.petLayer == .top, !pet.hopping, !pet.dragging else { return false }
        let ledges = windowLedges()
        if let current = ledge {
            let others = ledges.filter { $0.windowID != current.windowID }
            switch Double.random(in: 0..<1) {
            case ..<0.4: jumpDown()
            case ..<0.7 where !others.isEmpty: jump(onto: others.randomElement()!)
            default: walkAlong(current)
            }
            return true
        }
        guard Double.random(in: 0..<1) < 0.5, let target = nearest(ledges) else { return false }
        jump(onto: target)
        return true
    }

    /// Jumps onto a window now (test hook; also the menu's hop when something is in reach).
    func climbNow() {
        if let target = nearest(windowLedges().filter { $0.windowID != ledge?.windowID }) { jump(onto: target) }
    }

    func jumpDown() {
        guard ledge != nil, let area = screen?.visibleFrame else { return }
        let centre = pet.characterOrigin.x + windowHalf + .random(in: -160...160)
        let x = min(max(centre, area.minX + bodyHalf), area.maxX - bodyHalf) - windowHalf
        ledge = nil
        stopWatching()
        pet.leap(to: NSPoint(x: x, y: floorY))
    }

    /// The owner dropped the pet: standing on a window edge if its feet are on one.
    func ownerDropped() {
        ledge = nil
        stopWatching()
        guard AppSettings.shared.petLayer == .top, let found = support(near: pet.characterOrigin, tolerance: 14) else { return }
        ledge = found
        pet.shift(to: NSPoint(x: pet.characterOrigin.x, y: found.y - pet.feetGap))
        startWatching()
    }

    func ownerMoved() {
        ledge = nil
        stopWatching()
    }

    // MARK: Moves

    /// A reachable ledge, preferring near ones.
    private func nearest(_ ledges: [Ledge]) -> Ledge? {
        let centre = pet.characterOrigin.x + windowHalf
        let ranked = ledges.sorted { abs(min(max(centre, $0.minX), $0.maxX) - centre) < abs(min(max(centre, $1.minX), $1.maxX) - centre) }
        return ranked.prefix(3).randomElement()
    }

    private func jump(onto target: Ledge) {
        let centre = pet.characterOrigin.x + windowHalf
        let lo = target.minX + bodyHalf, hi = target.maxX - bodyHalf
        guard hi > lo else { return }
        // Land near the side it comes from, a little inside the edge.
        let landing = min(max(centre + .random(in: -120...120), lo), hi)
        ledge = target
        stopWatching()
        pet.leap(to: NSPoint(x: landing - windowHalf, y: target.y - pet.feetGap)) { [weak self] in self?.startWatching() }
    }

    private func walkAlong(_ current: Ledge) {
        let lo = current.minX + bodyHalf, hi = current.maxX - bodyHalf
        guard hi - lo > 80 else { return jumpDown() }
        let target = CGFloat.random(in: lo...hi) - windowHalf
        pet.wander(to: target)
    }

    // MARK: Support

    /// The ledge under the paws of a character at `origin` (within `tolerance` points), if any.
    private func support(near origin: NSPoint, tolerance: CGFloat, in ledges: [Ledge]? = nil) -> Ledge? {
        let centre = origin.x + windowHalf, paws = origin.y + pet.feetGap
        let candidates = (ledges ?? windowLedges()).filter {
            abs($0.y - paws) <= tolerance && centre >= $0.minX - bodyHalf * 0.5 && centre <= $0.maxX + bodyHalf * 0.5
        }
        return candidates.first { $0.windowID == ledge?.windowID } ?? candidates.first
    }

    private func startWatching() {
        stopWatching()
        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.check() } }
        RunLoop.main.add(t, forMode: .common)
        watchTimer = t
    }

    private func stopWatching() {
        watchTimer?.invalidate()
        watchTimer = nil
    }

    /// While standing on a window: ride along when it moves, fall when it is gone.
    private func check() {
        guard ledge != nil, !pet.dragging else { return }
        guard !pet.hopping else { return }
        let origin = pet.characterOrigin
        let ledges = windowLedges()
        // The same window is followed wherever it moves; another window only takes over right under the paws.
        if let found = support(near: origin, tolerance: .greatestFiniteMagnitude, in: ledges.filter { $0.windowID == ledge?.windowID })
            ?? support(near: origin, tolerance: 6, in: ledges) {
            ledge = found
            let centre = origin.x + windowHalf
            let x = min(max(centre, found.minX), found.maxX) - windowHalf
            let y = found.y - pet.feetGap
            if abs(y - origin.y) > 0.5 || abs(x - origin.x) > 0.5 { pet.shift(to: NSPoint(x: x, y: y)) }
            return
        }
        // Nothing below the feet: fall onto the highest window edge underneath, or to the floor.
        let centre = origin.x + windowHalf
        let paws = origin.y + pet.feetGap
        let below = ledges.filter { $0.y < paws - 2 && centre >= $0.minX && centre <= $0.maxX }.max { $0.y < $1.y }
        ledge = below
        if below == nil { stopWatching() }
        pet.fall(to: below.map { $0.y - pet.feetGap } ?? floorY)
    }
}
