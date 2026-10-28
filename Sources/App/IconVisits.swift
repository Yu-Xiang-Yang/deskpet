import AppKit

/// The pet and the desktop icons. It notices a file newly put on the desktop (a download, a screenshot) and goes to
/// look: ears up, a jump onto the file's icon, a sniff, a swipe of the paw, a word about it. Now and then it also
/// goes to sit on an icon of its own accord. After a while it jumps back down; it falls when a window covers the
/// icon or the icon goes away, and follows when the owner moves it. With the owner's leave (settings) it nudges the
/// icon it sits on a little aside, and puts it back before it leaves.
///
/// Finder reports the icons' names and positions to an AppleScript run through osascript, so that the app never
/// waits for it; macOS asks the owner once to let DeskPet control Finder. Only icons the pet can be seen on are
/// visited: on the main screen (where Finder draws them) with the pet on it, no window over them, and low enough
/// for the pet to stand on them below the menu bar.
@MainActor
final class IconVisits {
    /// Seconds between readings of the icons, and while the pet sits on one.
    static let pollInterval: TimeInterval = 12
    static let perchedPollInterval: TimeInterval = 3
    /// Seconds between visits of the pet's own accord, and how long it stays on an icon.
    static let interval: ClosedRange<Double> = 360...720
    static let stay: ClosedRange<Double> = 20...45
    /// A new file is visited within this long of its arrival (the owner may be typing meanwhile).
    static let arrivalPatience: TimeInterval = 120

    private let settings = AppSettings.shared
    private unowned let pet: PetWindowController
    /// Whether the pet may go now (owner around and not typing, pet shown, nothing else going on).
    var canAct: () -> Bool = { false }
    /// Whether the pet is in the desktop film: then the film's character goes to a new file's icon (`visitInFilm`)
    /// and the film visits icons on its own; `onIcons` keeps it told where they are (pictures, screen coordinates).
    var inFilm: () -> Bool = { false }
    var visitInFilm: ((String) -> Void)?
    var onIcons: (([(name: String, frame: NSRect)]) -> Void)?
    /// The pet leaves the window edge it may stand on (the climber lets go of it).
    var willLeap: (() -> Void)?

    struct Perch {
        var name: String
        var frame: NSRect
        /// Where the icon was before the pet nudged it (Finder coordinates), until it is put back.
        var nudgedFrom: CGPoint?
    }
    /// The icon the pet sits on.
    private(set) var perch: Perch?

    private var iconSize: CGFloat = 64
    private var items: [DesktopItems.Item] = []
    private var known: Set<String>?
    private var arrival: (item: DesktopItems.Item, at: Date)?
    private var nextVisit = Date().addingTimeInterval(.random(in: 120...300))
    private var reading = false
    private var denied = false
    private var lastRead = Date.distantPast
    private var lastError: Int?
    private var onIconsSent: Bool?
    private var timer: Timer?
    private var watchTimer: Timer?
    /// Changes whenever a visit starts or is called off; scheduled steps of an older visit then do nothing.
    private var visit = 0

    /// What the pet did at an icon, in words: the pet's mind decides whether to say something about it.
    var onEvent: ((String) -> Void)?

    init(pet: PetWindowController) {
        self.pet = pet
    }

    // MARK: On and off

    func setEnabled(_ on: Bool) {
        if on {
            guard timer == nil else { return }
            denied = false
            restoreNudged()
            let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else {
            timer?.invalidate()
            timer = nil
            leave(jump: false)
            known = nil
            arrival = nil
            items = []
            onIconsSent = nil
            onIcons?([])
        }
    }

    // MARK: Reading the icons

    private static let readScript = """
    tell application "Finder"
        set s to 64
        try
            set s to icon size of icon view options of window of desktop
        end try
        set out to (s as text)
        set ps to desktop position of every item of desktop
        set ns to name of every item of desktop
        repeat with i from 1 to count of ns
            set p to item i of ps
            set out to out & linefeed & ((item 1 of p) as text) & tab & ((item 2 of p) as text) & tab & (item i of ns)
        end repeat
        return out
    end tell
    """

    private func tick() {
        guard !denied, !reading else { return }
        let every = perch == nil ? Self.pollInterval : Self.perchedPollInterval
        guard Date().timeIntervalSince(lastRead) >= every, Self.iconsShown, PetBrain.idleSeconds < 120 || perch != nil else { return }
        reading = true
        lastRead = Date()
        Self.runFinder(Self.readScript) { [weak self] result in
            guard let self else { return }
            self.reading = false
            switch result {
            case .success(let output):
                self.lastError = nil
                let parsed = DesktopItems.parse(output)
                self.iconSize = parsed.iconSize
                self.read(parsed.items)
            case .failure(let error):
                self.lastError = error.code
                // -1743: not allowed to control Finder. The owner decides in System Settings; the pet says so once.
                guard error.code == -1743 else { return }
                self.denied = true
                self.pet.say(tr("没有获得控制“访达”的权限，读不到桌面图标。可在 系统设置 → 隐私与安全性 → 自动化 中允许 DeskPet。",
                                "I may not control Finder, so I can't see the desktop icons. Allow DeskPet in System Settings → Privacy & Security → Automation."),
                             kind: "error", ms: 12000)
            }
        }
    }

    private func read(_ now: [DesktopItems.Item]) {
        if now != items || onIconsSent == nil {
            onIconsSent = true
            onIcons?(now.compactMap { item in frame(of: item).map { (item.name, $0) } })
        }
        items = now
        if let known {
            if let first = DesktopItems.newcomers(before: known, now: now).first { arrival = (first, Date()) }
        }
        known = Set(now.map(\.name))
        if perch != nil { checkPerchedIcon() } else { consider() }
    }

    // MARK: Deciding

    private func consider() {
        if let a = arrival {
            guard Date().timeIntervalSince(a.at) < Self.arrivalPatience, items.contains(where: { $0.name == a.item.name }) else {
                arrival = nil
                return
            }
            if inFilm() {
                arrival = nil
                visitInFilm?(a.item.name)
                return
            }
            guard canAct() else { return }  // later, while it is still new
            arrival = nil
            go(to: a.item, arrived: true)
            return
        }
        guard Date() >= nextVisit, canAct(), !inFilm() else { return }
        nextVisit = Date().addingTimeInterval(.random(in: Self.interval))
        if let item = items.filter({ landing(on: $0) != nil }).randomElement() { go(to: item, arrived: false) }
    }

    /// Visits an icon now (menu, test hook): a new file's (`arrived`) or one of the pet's own choosing, the nearest
    /// first. Returns false when no icon is in reach.
    @discardableResult
    func visitNow(arrived: Bool = false, name: String? = nil) -> Bool {
        let x = pet.characterOrigin.x + pet.panel.frame.width / 2
        let candidates = items.filter { (name == nil || $0.name == name) && landing(on: $0) != nil }
        guard let item = candidates.min(by: { abs((frame(of: $0)?.midX ?? 0) - x) < abs((frame(of: $1)?.midX ?? 0) - x) }) else { return false }
        go(to: item, arrived: arrived)
        return true
    }

    // MARK: Where the icons are

    /// Whether Finder shows icons on the desktop (it may be told not to, and Stage Manager can hide them).
    static var iconsShown: Bool {
        func flag(_ key: String, _ domain: String) -> Bool? {
            CFPreferencesCopyAppValue(key as CFString, domain as CFString) as? Bool
        }
        if flag("CreateDesktop", "com.apple.finder") == false { return false }
        if flag("GloballyEnabled", "com.apple.WindowManager") == true { return flag("HideDesktop", "com.apple.WindowManager") != true }
        return flag("StandardHideDesktopIcons", "com.apple.WindowManager") != true
    }

    private var mainScreen: NSScreen? { NSScreen.screens.first }

    private func frame(of item: DesktopItems.Item) -> NSRect? {
        guard let screen = mainScreen else { return nil }
        return DesktopItems.pictureFrame(of: item, iconSize: iconSize, mainScreenHeight: screen.frame.height)
    }

    /// Where the character's origin goes to stand on `item`, if the pet can be seen there.
    private func landing(on item: DesktopItems.Item) -> (origin: NSPoint, frame: NSRect)? {
        guard let screen = mainScreen, let frame = frame(of: item) else { return nil }
        let visible = screen.visibleFrame, f = pet.panel.frame
        // The pet stays on its screen (the main one, where the icons are).
        guard screen.frame.contains(NSPoint(x: f.midX, y: pet.characterOrigin.y + 10)) else { return nil }
        // Room above the icon for the whole character below the menu bar, the icon on screen, no window over it.
        guard visible.contains(NSPoint(x: frame.midX, y: frame.midY)),
              frame.maxY + pet.characterHeight + 4 <= visible.maxY,
              !Self.covered(frame) else { return nil }
        // The picture's transparent margin: the paws on its visible top.
        let top = frame.maxY - iconSize * 0.08
        return (NSPoint(x: frame.midX - f.width / 2, y: top - pet.feetGap), frame)
    }

    /// Whether another app's window lies over the middle of `rect` (window bounds need no permission).
    static func covered(_ rect: NSRect) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        let own = ProcessInfo.processInfo.processIdentifier
        let flipY = NSScreen.screens.first?.frame.maxY ?? 0
        let probe = NSPoint(x: rect.midX, y: rect.midY)
        return list.contains { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0, (info[kCGWindowOwnerPID as String] as? pid_t) != own,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.1,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary, let b = CGRect(dictionaryRepresentation: dict) else { return false }
            return NSRect(x: b.minX, y: flipY - b.maxY, width: b.width, height: b.height).contains(probe)
        }
    }

    // MARK: A visit

    private func go(to item: DesktopItems.Item, arrived: Bool) {
        guard perch == nil, !pet.hopping, !pet.dragging, let target = landing(on: item) else { return }
        visit += 1
        let id = visit
        if arrived {
            pet.play(.perk)
            pet.meow(.trill, chance: 0.5)
        }
        after(arrived ? 0.8 : 0, id) { [self] in
            guard !pet.hopping, !pet.dragging else { return }
            let target = landing(on: item) ?? target
            willLeap?()
            perch = Perch(name: item.name, frame: target.frame, nudgedFrom: nil)
            pet.leap(to: target.origin) { [weak self] in self?.landed(item, arrived: arrived, id: id) }
            // A leap that did not happen (the pet was busy after all) leaves no visit behind.
            after(4, id) { [self] in if watchTimer == nil { visit += 1; perch = nil } }
        }
    }

    private func landed(_ item: DesktopItems.Item, arrived: Bool, id: Int) {
        guard id == visit, perch != nil else { return }
        startWatching()
        pet.play(.sniff)
        after(2.5, id) { [self] in
            pet.play(.swipe)
            pet.meow(.mew, chance: 0.4)
            let kind = DesktopItems.kind(of: item.name).label
            onEvent?(arrived ? "桌面上刚出现一个新\(kind)「\(item.name)」，你跳到它的图标上嗅了嗅、用爪子拍了拍"
                             : "你跳到了桌面上\(kind)「\(item.name)」的图标上坐着")
        }
        if settings.iconNudge { after(4.6, id) { [self] in nudge() } }
        let stay = Double.random(in: Self.stay)
        after(stay * 0.55, id) { [self] in pet.play(Bool.random() ? .groom : .stretch) }
        after(stay, id) { [self] in leave(jump: true) }
    }

    /// Ends a visit: the nudged icon goes back to its place, then the pet jumps down beside it (`jump`).
    func leave(jump: Bool) {
        visit += 1
        stopWatching()
        guard let p = perch else { return }
        if p.nudgedFrom != nil {
            putBack(p) { [weak self] in
                guard let self else { return }
                self.perch = nil
                if jump { self.jumpDown() }
            }
        } else {
            perch = nil
            if jump { jumpDown() }
        }
    }

    private func jumpDown() {
        guard !pet.dragging, let screen = mainScreen else { return }
        let area = screen.visibleFrame, half = pet.panel.frame.width / 2
        let centre = pet.characterOrigin.x + half + .random(in: -140...140)
        let x = min(max(centre, area.minX + half * 0.5), area.maxX - half * 0.5) - half
        pet.leap(to: NSPoint(x: x, y: area.minY))
    }

    /// The owner picked the pet up: the visit is over (a nudged icon goes back without it).
    func ownerMoved() {
        guard perch != nil else { return }
        leave(jump: false)
    }

    /// The owner dropped the pet: standing on an icon if its paws are on one's top.
    func ownerDropped() {
        guard settings.iconPlay, perch == nil else { return }
        let o = pet.characterOrigin, half = pet.panel.frame.width / 2
        let paws = o.y + pet.feetGap, centre = o.x + half
        for item in items {
            guard let f = frame(of: item), abs(f.maxY - iconSize * 0.08 - paws) < 18, abs(f.midX - centre) < iconSize * 0.6,
                  landing(on: item) != nil else { continue }
            visit += 1
            perch = Perch(name: item.name, frame: f, nudgedFrom: nil)
            pet.shift(to: NSPoint(x: f.midX - half, y: f.maxY - iconSize * 0.08 - pet.feetGap))
            startWatching()
            let id = visit
            pet.play(.sniff)
            after(Double.random(in: Self.stay), id) { [self] in leave(jump: true) }
            return
        }
    }

    /// The pet is needed elsewhere (the chat box opened, the film started, …): the visit ends where it is.
    func interrupt() {
        guard perch != nil else { return }
        leave(jump: false)
    }

    // MARK: While on an icon

    private func startWatching() {
        stopWatching()
        let t = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.watch() } }
        RunLoop.main.add(t, forMode: .common)
        watchTimer = t
    }

    private func stopWatching() {
        watchTimer?.invalidate()
        watchTimer = nil
    }

    /// A window over the icon: the pet falls to the floor.
    private func watch() {
        guard let p = perch, !pet.hopping, !pet.dragging else { return }
        if Self.covered(p.frame) { fallOff() }
    }

    /// After a reading: the icon gone (deleted, renamed) makes the pet fall; moved by the owner, the pet follows.
    private func checkPerchedIcon() {
        guard var p = perch, !pet.hopping, !pet.dragging else { return }
        guard let item = items.first(where: { $0.name == p.name }), let f = frame(of: item) else { return fallOff() }
        guard p.nudgedFrom == nil, abs(f.midX - p.frame.midX) > 3 || abs(f.midY - p.frame.midY) > 3 else { return }
        guard let target = landing(on: item) else { return fallOff() }
        p.frame = f
        perch = p
        pet.leap(to: target.origin)
    }

    private func fallOff() {
        guard let screen = mainScreen else { return }
        leave(jump: false)
        pet.fall(to: screen.visibleFrame.minY)
    }

    // MARK: Nudging

    private static let nudgedKey = "iconNudged"

    /// Pushes the icon under the pet towards the middle of the screen by about its width, riding along.
    private func nudge() {
        guard var p = perch, p.nudgedFrom == nil, !pet.hopping, let screen = mainScreen,
              let item = items.first(where: { $0.name == p.name }) else { return }
        let dx = (item.center.x > screen.frame.width / 2 ? -1 : 1) * iconSize * 0.75
        let to = CGPoint(x: item.center.x + dx, y: item.center.y)
        p.nudgedFrom = item.center
        perch = p
        // Remembered until put back, so that a quit or crash in between does not leave it there.
        UserDefaults.standard.set(["name": p.name, "x": item.center.x, "y": item.center.y], forKey: Self.nudgedKey)
        pet.play(.swipe)
        Self.move(p.name, to: to) { [weak self] ok in
            guard let self, ok, var q = self.perch, q.name == p.name else { return }
            q.frame = q.frame.offsetBy(dx: dx, dy: 0)
            self.perch = q
            self.pet.wander(to: self.pet.characterOrigin.x + dx)
        }
    }

    private func putBack(_ p: Perch, then done: @escaping () -> Void) {
        guard let from = p.nudgedFrom else { return done() }
        pet.play(.swipe)
        Self.move(p.name, to: from) { [weak self] ok in
            guard let self else { return }
            if ok { UserDefaults.standard.removeObject(forKey: Self.nudgedKey) }
            // The pet rides back with the icon.
            if ok, let q = self.perch, q.name == p.name, !self.pet.dragging,
               let home = self.frame(of: DesktopItems.Item(name: p.name, center: from)) {
                self.pet.wander(to: self.pet.characterOrigin.x + home.midX - q.frame.midX)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { done() }  // after the hop back
        }
    }

    /// An icon nudged before a quit goes back to its place.
    private func restoreNudged() {
        guard let saved = UserDefaults.standard.dictionary(forKey: Self.nudgedKey), let name = saved["name"] as? String,
              let x = saved["x"] as? Double, let y = saved["y"] as? Double else { return }
        Self.move(name, to: CGPoint(x: x, y: y)) { ok in
            if ok { UserDefaults.standard.removeObject(forKey: Self.nudgedKey) }
        }
    }

    private static func move(_ name: String, to point: CGPoint, done: @escaping (Bool) -> Void) {
        let quoted = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Finder\" to set desktop position of item \"\(quoted)\" of desktop to {\(Int(point.x.rounded())), \(Int(point.y.rounded()))}"
        runFinder(script) { result in
            if case .success = result { done(true) } else { done(false) }
        }
    }

    // MARK: Helpers

    /// Runs `body` after `seconds` if visit `id` is still going on.
    private func after(_ seconds: Double, _ id: Int, _ body: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.visit == id else { return }
            body()
        }
    }

    /// Runs AppleScript through osascript off the main thread; the result (output, or the AppleScript error
    /// number) comes back on the main thread.
    private static func runFinder(_ source: String, completion: @escaping (Result<String, FinderError>) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", source]
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            guard (try? p.run()) != nil else {
                DispatchQueue.main.async { completion(.failure(FinderError(code: 0))) }
                return
            }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let errors = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            let status = p.terminationStatus
            DispatchQueue.main.async {
                if status == 0 {
                    var text = String(decoding: data, as: UTF8.self)
                    if text.hasSuffix("\n") { text.removeLast() }
                    completion(.success(text))
                } else {
                    // osascript reports "… (-1743)" at the end of its message.
                    let code = errors.range(of: #"\((-?\d+)\)\s*$"#, options: .regularExpression)
                        .flatMap { Int(errors[$0].trimmingCharacters(in: CharacterSet(charactersIn: "() \n"))) } ?? 0
                    completion(.failure(FinderError(code: code)))
                }
            }
        }
    }

    struct FinderError: Error { var code: Int }

    /// The state, for test runs: readings, icons with their frames and whether the pet could stand on them.
    var report: String {
        var lines = ["enabled \(timer != nil) denied \(denied) shown \(Self.iconsShown) size \(iconSize) error \(lastError.map(String.init) ?? "-")",
                     "perch \(perch.map { "\($0.name) \(NSStringFromRect($0.frame))" } ?? "-")"]
        for item in items {
            let f = frame(of: item).map(NSStringFromRect) ?? "?"
            let covered = frame(of: item).map(Self.covered) ?? false
            lines.append("\(item.name)\t\(item.center)\t\(f)\tcovered \(covered)\treachable \(landing(on: item) != nil)")
        }
        return lines.joined(separator: "\n")
    }
}
