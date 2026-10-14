import AppKit
import CoreGraphics

/// The pet's occasional pranks: pretending to sleep, peeking out from behind a screen edge, sneaking up
/// to the mouse pointer, and sulking when petted too often. Spontaneous pranks happen only while the
/// owner is around but not typing, at most once every 8–15 minutes; a click on the pet ends one.
@MainActor
final class Mischief {
    private let settings = AppSettings.shared
    private unowned let pet: PetWindowController
    /// Whether the pet may act on its own right now (visible, not in research mode, chat box closed, …).
    var canAct: () -> Bool = { false }
    /// Whether the pet is really asleep (the owner is away), as opposed to pretending.
    var reallyAsleep: () -> Bool = { false }

    private enum Prank {
        case none
        case fakeSleep(until: Date)
        case peek(returnX: CGFloat, until: Date)
    }
    private var prank = Prank.none
    private var next = Date().addingTimeInterval(.random(in: 300...600))
    private var pats: [Date] = []
    private var sulkingUntil = Date.distantPast

    /// Seconds between spontaneous pranks.
    static let interval: ClosedRange<Double> = 480...900
    /// Pats within `patWindow` seconds that make the pet sulk.
    static let patsToSulk = 4
    static let patWindow: TimeInterval = 15

    init(pet: PetWindowController) {
        self.pet = pet
    }

    var busy: Bool {
        if case .none = prank { return false }
        return true
    }

    /// Seconds since the last key press: the owner is typing when this is short.
    static var keyboardIdleSeconds: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
    }

    // MARK: Music
    // While music plays the pet dances rather than pranks; these small jokes fit into the dance.

    /// Whether the pet may joke during music (visible, not in research mode, chat box closed, owner around).
    var canJoke: () -> Bool = { false }
    /// Start of the current listening session; gaps of a few seconds between songs do not end it.
    private var musicSince: Date?
    private var nextSing = Date.distantFuture
    private var nextJump = Date.distantFuture
    private var lastEncore = Date.distantPast
    private var sessionEnd: DispatchWorkItem?

    func musicChanged(_ playing: Bool) {
        sessionEnd?.cancel()
        if playing {
            interrupt()  // the music comes first
            if musicSince == nil {
                musicSince = Date()
                nextSing = Date().addingTimeInterval(.random(in: 90...240))
                nextJump = Date().addingTimeInterval(.random(in: 60...180))
            }
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.musicSessionEnded() }
        sessionEnd = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }

    /// Each beat: now and then sing along (every 4–8 min, not while the owner types) or jump on a
    /// strong beat (every 3–6 min; any beat once a minute has passed without a strong one).
    func musicBeat(_ strength: Double) {
        guard settings.mischief, musicSince != nil else { return }
        let now = Date()
        if now >= nextSing {
            nextSing = now.addingTimeInterval(.random(in: 240...480))
            if canJoke(), Self.keyboardIdleSeconds >= 10 {
                pet.say([tr("♪～啦啦啦～♪", "♪~la la la~♪"),
                         tr("♪ 嗯嗯～哼哼哼～ ♪", "♪ mm-mm~ hmm hmm hmm~ ♪"),
                         tr("（跟着唱）♪～", "(singing along) ♪~"),
                         tr("这段我会唱！♪～", "I know this part! ♪~")].randomElement()!, ms: 5000)
            }
        }
        if now >= nextJump, strength >= 0.85 || now.timeIntervalSince(nextJump) > 60 {
            nextJump = now.addingTimeInterval(.random(in: 180...360))
            if canJoke() {
                pet.bounce()
                if Bool.random() { pet.say(tr("嗨～！", "Woo~!"), ms: 2500) }
            }
        }
    }

    /// Eight seconds of silence after at least two minutes of music: the pet asks for more (at most every 20 min).
    private func musicSessionEnded() {
        guard let since = musicSince else { return }
        musicSince = nil
        guard settings.mischief, Date().timeIntervalSince(since) >= 120,
              Date().timeIntervalSince(lastEncore) > 1200, canJoke() else { return }
        lastEncore = Date()
        pet.play(.sad)
        pet.say([tr("再放一首嘛～", "One more song~"),
                 tr("诶，怎么停了？我还没跳够呢！", "Huh, it stopped? I wasn't done dancing!"),
                 tr("安可！安可！", "Encore! Encore!")].randomElement()!)
    }

    // MARK: Pranks timer

    /// Called every few seconds by the app.
    func tick() {
        let now = Date()
        switch prank {
        case .fakeSleep(let until):
            if now >= until { endFakeSleep() }
        case .peek(let returnX, let until):
            if now >= until { endPeek(returnX: returnX, caught: false) }
        case .none:
            guard settings.mischief, now >= next else { return }
            guard canAct(), Self.keyboardIdleSeconds >= 20 else {
                next = now.addingTimeInterval(.random(in: 30...90))  // try again after the owner pauses
                return
            }
            next = now.addingTimeInterval(.random(in: Self.interval))
            switch Int.random(in: 0..<3) {
            case 0: startFakeSleep()
            case 1: startPeek()
            default: sneakToPointer()
            }
        }
    }

    /// Starts a prank at once (test hook): "sleep", "peek" or "sneak".
    func trigger(_ name: String) {
        interrupt()
        switch name {
        case "sleep": startFakeSleep()
        case "peek": startPeek()
        case "sneak": sneakToPointer()
        case "sing": musicSince = musicSince ?? Date(); nextSing = .distantPast; musicBeat(0.5)
        case "jump": musicSince = musicSince ?? Date(); nextJump = .distantPast; musicBeat(1)
        case "encore": musicSince = Date().addingTimeInterval(-300); lastEncore = .distantPast; musicSessionEnded()
        default: break
        }
    }

    // MARK: Owner actions

    /// A click on the pet during a prank: the pet admits it. Returns false when no prank was going on.
    func caught() -> Bool {
        switch prank {
        case .none:
            return false
        case .fakeSleep:
            endFakeSleep()
            pet.play(.happy)
            pet.say([tr("嘿嘿，被发现了！其实我是装睡的～", "Hehe, you caught me! I was only pretending~"),
                     tr("呼……呼……诶？你怎么知道我没睡！", "Zzz… huh? How did you know I was awake!")].randomElement()!)
        case .peek(let returnX, _):
            endPeek(returnX: returnX, caught: true)
        }
        return true
    }

    /// A pat on the head. Returns true when the pet sulks instead of enjoying it.
    func sulkAtPat() -> Bool {
        guard settings.mischief else { return false }
        let now = Date()
        if now < sulkingUntil {
            pet.play(.shake)
            pet.say([tr("哼！说了不给摸了！", "Hmph! I said no more pats!"),
                     tr("(｀へ´) 不理你。", "(｀へ´) Not talking to you.")].randomElement()!)
            return true
        }
        pats = pats.filter { now.timeIntervalSince($0) < Self.patWindow } + [now]
        guard pats.count >= Self.patsToSulk else { return false }
        pats = []
        sulkingUntil = now.addingTimeInterval(30)
        pet.play(.shake)
        pet.say(tr("摸太多啦！头发都乱了，我生气了，哼！", "Too many pats! You messed up my fur. Hmph!"))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.stompOff() }
        return true
    }

    /// The owner opened the chat box, switched modes, etc.: a prank in progress ends quietly.
    func interrupt() {
        switch prank {
        case .none: break
        case .fakeSleep: endFakeSleep()
        case .peek(let returnX, _): endPeek(returnX: returnX, caught: false)
        }
    }

    /// The owner dragged the pet somewhere: it stays there.
    func ownerMoved() {
        if case .fakeSleep = prank { endFakeSleep() }
        prank = .none
    }

    // MARK: Pranks

    private func startFakeSleep() {
        prank = .fakeSleep(until: Date().addingTimeInterval(.random(in: 40...90)))
        pet.setSleeping(true)
    }

    private func endFakeSleep() {
        prank = .none
        if !reallyAsleep() { pet.setSleeping(false) }
    }

    /// Hops to the nearer outer screen edge until about half of the character is hidden, then looks out.
    /// An edge shared with another display is not used: the pet would cross over to that display.
    private func startPeek() {
        guard let screen = currentScreen else { return }
        let area = screen.visibleFrame
        let frame = pet.panel.frame
        let edges = frame.midX > area.midX ? [true, false] : [false, true]
        guard let toRight = edges.first(where: { Self.isOuterEdge(of: screen, right: $0) }) else { return startFakeSleep() }
        let target = toRight ? area.maxX - frame.width * 0.58 : area.minX - frame.width * 0.42
        let returnX = frame.minX
        prank = .peek(returnX: returnX, until: Date().addingTimeInterval(.random(in: 25...45)))
        pet.wander(to: target) { [weak self] in
            guard let self, case .peek = self.prank else { return }
            self.pet.play(.shy)
            self.pet.say(tr("（偷看）👀", "(peeking) 👀"), ms: 5000)
        }
    }

    private func endPeek(returnX: CGFloat, caught: Bool) {
        prank = .none
        pet.cancelHop()
        if caught {
            pet.play(.happy)
            pet.say([tr("被你发现了～", "You found me~"),
                     tr("嘿嘿，我在玩捉迷藏！", "Hehe, I was playing hide-and-seek!")].randomElement()!)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.pet.wander(to: returnX) }
        } else {
            pet.wander(to: returnX)
        }
    }

    /// Hops to just below the mouse pointer (at most 520 pt) and says so.
    private func sneakToPointer() {
        let mouse = NSEvent.mouseLocation
        guard let area = screenArea, currentScreen?.frame.contains(mouse) == true else { return startFakeSleep() }
        let frame = pet.panel.frame
        let minX = area.minX - frame.width * 0.25, maxX = area.maxX - frame.width * 0.75
        var target = min(max(mouse.x - frame.width / 2, minX), maxX)
        guard abs(target - frame.minX) > 120 else { return startFakeSleep() }
        target = frame.minX + max(-520, min(520, target - frame.minX))
        pet.wander(to: target) { [weak self] in
            self?.pet.play(.happy)
            self?.pet.say([tr("嘿嘿，偷偷跟过来了～", "Hehe, I sneaked over~"),
                           tr("抓到你的鼠标啦！", "Got your mouse pointer!"),
                           tr("你在看什么呀？让我也看看～", "What are you looking at? Let me see~")].randomElement()!)
        }
    }

    /// After sulking: a few hops away from the pointer.
    private func stompOff() {
        guard let area = screenArea, !pet.dragging else { return }
        let frame = pet.panel.frame
        let minX = area.minX - frame.width * 0.25, maxX = area.maxX - frame.width * 0.75
        let away: CGFloat = NSEvent.mouseLocation.x > frame.midX ? -1 : 1
        var target = frame.minX + away * 260
        if target < minX || target > maxX { target = frame.minX - away * 260 }
        pet.wander(to: min(max(target, minX), maxX))
    }

    /// The screen under the middle of the pet window.
    private var currentScreen: NSScreen? {
        let f = pet.panel.frame
        return NSScreen.screens.first { $0.frame.contains(NSPoint(x: f.midX, y: f.midY)) } ?? pet.panel.screen
    }

    private var screenArea: NSRect? { currentScreen?.visibleFrame }

    /// Whether no other display adjoins `screen` on that side.
    static func isOuterEdge(of screen: NSScreen, right: Bool) -> Bool {
        let f = screen.frame
        return !NSScreen.screens.contains { other in
            let o = other.frame
            guard o != f, o.maxY > f.minY, o.minY < f.maxY else { return false }
            return right ? abs(o.minX - f.maxX) < 2 : abs(o.maxX - f.minX) < 2
        }
    }
}
