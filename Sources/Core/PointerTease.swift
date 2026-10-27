import CoreGraphics
import Foundation

/// When the pointer plays above the pet's head, the pet reaches for it with both forepaws (motion "grab"). The pointer
/// has to move about in the zone above the upper body for `needed` seconds in all (a still pointer keeps what has been
/// gathered, time outside the zone takes it back twice as fast), and at least `cooldown` seconds pass between grabs.
struct PointerTease {
    static let needed: TimeInterval = 0.8
    static let cooldown: TimeInterval = 25

    private(set) var teased: TimeInterval = 0
    private var last: (point: CGPoint, time: Date)?
    private var lastGrab = Date.distantPast

    /// Above the upper body of the character drawn in `stage` (feet at its bottom): 70% of its width, from the middle
    /// of its height to 40% of its height above its top.
    static func zone(stage: CGRect) -> CGRect {
        CGRect(x: stage.midX - stage.width * 0.35, y: stage.minY + stage.height * 0.55,
               width: stage.width * 0.7, height: stage.height * 0.85)
    }

    /// One look at the pointer (screen coordinates); true when the pet should reach for it now. While not `allowed`
    /// (dragged, hopping, asleep, …) nothing is gathered.
    mutating func update(pointer: CGPoint, zone: CGRect, now: Date, allowed: Bool) -> Bool {
        defer { last = (pointer, now) }
        guard let last, allowed else {
            teased = 0
            return false
        }
        let dt = max(0, min(0.2, now.timeIntervalSince(last.time)))
        let inside = zone.contains(pointer)
        if !inside {
            teased = max(0, teased - 2 * dt)
        } else if hypot(pointer.x - last.point.x, pointer.y - last.point.y) >= 2 {
            teased += dt
        }
        guard teased >= Self.needed, now.timeIntervalSince(lastGrab) >= Self.cooldown else { return false }
        teased = 0
        lastGrab = now
        return true
    }
}
