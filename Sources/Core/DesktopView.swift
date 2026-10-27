import CoreGraphics
import Foundation

/// Whether the desktop of a screen is in view, judged from the windows of other apps on it: the desktop film
/// (DesktopFilm) plays while it is.
enum DesktopView {
    /// In view at most this share of the screen covered; out of view above `leaveAbove`. In between, the state is kept.
    static let enterAtMost = 0.2
    static let leaveAbove = 0.3

    /// Share of `screen` (0…1) covered by `windows`, sampled on a grid, so that overlapping windows count once.
    static func coverage(of screen: CGRect, by windows: [CGRect], columns: Int = 32, rows: Int = 20) -> Double {
        guard screen.width > 0, screen.height > 0, columns > 0, rows > 0 else { return 0 }
        let relevant = windows.filter { $0.intersects(screen) }
        guard !relevant.isEmpty else { return 0 }
        var covered = 0
        for r in 0..<rows {
            for c in 0..<columns {
                let p = CGPoint(x: screen.minX + (CGFloat(c) + 0.5) * screen.width / CGFloat(columns),
                                y: screen.minY + (CGFloat(r) + 0.5) * screen.height / CGFloat(rows))
                if relevant.contains(where: { $0.contains(p) }) { covered += 1 }
            }
        }
        return Double(covered) / Double(columns * rows)
    }
}

/// Debounces the in-view state: it changes only after `samples` consecutive readings call for the change, so that
/// a window animation (Mission Control, a window being dragged across) does not flip it. When the film may not play
/// at all (screen locked, pet hidden, …) the state turns off at once.
struct DesktopViewTracker {
    private(set) var inView = false
    private var streak = 0
    let samples: Int

    init(samples: Int = 2) { self.samples = samples }

    @discardableResult
    mutating func update(coverage: Double, allowed: Bool = true) -> Bool {
        let wanted: Bool
        if !allowed { wanted = false }
        else if coverage <= DesktopView.enterAtMost { wanted = true }
        else if coverage > DesktopView.leaveAbove { wanted = false }
        else { wanted = inView }
        guard wanted != inView else { streak = 0; return inView }
        streak += 1
        if streak >= samples || !allowed {
            inView = wanted
            streak = 0
        }
        return inView
    }

    mutating func reset() {
        inView = false
        streak = 0
    }
}
