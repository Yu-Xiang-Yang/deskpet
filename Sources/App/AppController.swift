import AppKit
import Combine
import ServiceManagement

@MainActor
final class AppController: NSObject, NSApplicationDelegate, PetWindowDelegate, NSMenuDelegate {
    private let settings = AppSettings.shared
    private let pet = PetWindowController()
    private lazy var brain = PetBrain(pet: pet)
    /// The focus timer's notices (the owner's day goes to the pet's mind, see `reminders.onRoutine`).
    private lazy var reminders = ReminderScheduler { [weak self] text, motion in
        self?.mischief.interrupt()  // e.g. back from a screen edge, so that the bubble is fully visible
        self?.brain.notice(text, motion: motion)
    }
    // Alerts are no fixed lines: the pet's mind hears of them and decides whether to mention them.
    private lazy var weather = WeatherWatcher { [weak self] text, _ in self?.brain.consider(.event("收到一条天气提醒：" + text)) }
    private lazy var calendar = CalendarWatcher { entries in MemoryStore.shared.syncCalendar(entries, now: Date()) }
    private lazy var deepseekBalance = DeepSeekBalanceWatcher { [weak self] text, _ in self?.brain.consider(.event("收到一条余额提醒：" + text)) }
    private let speechBalance = SpeechBalanceWatcher()
    private let localVoice = LocalVoiceServer()
    private lazy var claudeUsage = ClaudeUsageWatcher { [weak self] text, _ in self?.brain.consider(.event("收到一条 Claude 额度提醒：" + text)) }
    private let engine = ResearchEngine()
    private lazy var research = ResearchWindowController(engine: engine)
    private let settingsWindow = SettingsWindowController()
    private let chatPanel = ChatInputPanel()
    private let approval = ApprovalPanel()
    private let agent = DshAgent()
    private var statusItem: NSStatusItem?

    /// In research mode the chat box asks the research assistant; answers appear as the pet's bubbles.
    private var researchMode = false
    /// The research conversation of the current research-mode session (created by the first question).
    private var researchConversationID: String?
    private var subscriptions = Set<AnyCancellable>()
    private var greeted = false
    private lazy var hotKey = GlobalHotKey { [weak self] in self?.toggleChatFromHotKey() }
    private var wanderTimer: Timer?
    private lazy var mischief = Mischief(pet: pet)
    private lazy var climber = Climber(pet: pet)
    private lazy var iconVisits = IconVisits(pet: pet)
    private let bootIntro = BootIntro()
    /// The live wallpaper the pet steps into while the desktop is in view.
    private let film = DesktopFilm()
    /// The owner hid the pet (menu); the desktop film does not play then either.
    private var petHidden = false
    /// While the login intro plays, the pet's greeting waits.
    private var introPlaying = false
    /// Since when the owner has been away (display asleep, screen locked or screen saver running).
    private var awaySince: Date?
    private var screenLocked = false
    private var returnWork: DispatchWorkItem?
    /// Shorter absences (a display that only dimmed for a moment) do not replay the intro.
    static let minimumAway: TimeInterval = 10
    private var petReady = false
    private let music = MusicMonitor()
    /// When the music being played started, for telling the pet how long it lasted.
    private var musicStarted: Date?
    private var nextWander = Date.distantFuture

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        buildStatusItem()

        pet.delegate = self
        pet.setLayer(settings.petLayer)
        pet.show(model: settings.selectedModel, scale: settings.petScale)

        // The owner's reminders are memories of the highest importance; the pet's mind gives them when due.
        brain.onRemind = { r in
            MemoryStore.shared.addReminder(r.text, at: Date().addingTimeInterval(Double(max(1, r.minutes)) * 60))
        }
        reminders.onRoutine = { [weak self] moment in self?.brain.consider(.routine(moment)) }
        reminders.onSnooze = { text in MemoryStore.shared.addReminder(text, at: Date().addingTimeInterval(600)) }
        brain.mind.notify = { [weak self] text in self?.reminders.notify(text) }
        brain.mind.onDance = { [weak self] dance in
            guard let self, self.music.playing else { return }
            self.pet.setGrooving(dance)
            if dance { self.mischief.musicChanged(true) }
        }
        mischief.onEvent = { [weak self] what in self?.brain.consider(.event(what)) }
        iconVisits.onEvent = { [weak self] what in self?.brain.consider(.event(what)) }
        brain.onOpenApp = { [weak self] name in
            AppLauncher.open(name) { self?.pet.say($0, kind: "memory") }
        }
        brain.onAddEvent = { [weak self] request in self?.addEvent(request) }
        brain.onAgentTask = { [weak self] task in self?.startAgentTask(task) }
        // The agent's and Claude Code's work (hand-overs, reports, errors) is shown, not read aloud.
        brain.onClaudeTask = { [weak self] request in self?.pet.say(ClaudeCodeLauncher.open(request), kind: "memory", aloud: false) }
        brain.onLidAwake = { [weak self] awake in LidSleep.set(awake: awake) { self?.pet.say($0, kind: "memory") } }
        agent.onStatus = { [weak self] status in self?.pet.setStatus(status) }
        // Reaching for the pointer only while the pet is free: awake, not in research mode, no prank, the chat box closed.
        pet.mayGrab = { [weak self] in
            guard let self else { return false }
            return !self.brain.sleeping && !self.researchMode && !self.mischief.busy && !self.chatPanel.isVisible
        }
        agent.ask = { [weak self] text, done in
            guard let self else { done(false); return }
            self.film.interrupt()  // the card hangs below the pet's own window
            self.approval.ask(text, below: self.pet.panel, done: done)
        }
        // Remarks of the pet's own accord wait while research mode, the chat box, the daily tasks or the intro are on.
        brain.mayInterrupt = { [weak self] in
            guard let self else { return false }
            return !self.researchMode && !self.chatPanel.isVisible && !self.dailyRunning && !self.introPlaying
        }
        MemoryStore.shared.semantic = MemoryEmbedding.similarities
        // The screen is looked at only while it is unlocked, the pet is awake and no intro plays.
        ScreenWatcher.shared.mayLook = { [weak self] in
            guard let self else { return false }
            return !self.screenLocked && !self.introPlaying && !self.brain.sleeping
        }
        ScreenWatcher.shared.start()
        brain.start()
        reminders.start()
        weather.start()
        claudeUsage.start()
        calendar.start()
        deepseekBalance.start()
        ClaudeCostWatcher.shared.start()
        brain.extraContext = { [weak self] in
            let lines = [ScreenWatcher.shared.contextLine, self?.calendar.contextLine, self?.deepseekBalance.contextLine,
                         ClaudeCostWatcher.shared.contextLine].compactMap { $0 }
            return lines.isEmpty ? nil : lines.joined(separator: "｜")
        }
        settings.$calendarAlerts.dropFirst().removeDuplicates().filter { $0 }.sink { [weak self] _ in
            self?.calendar.requestAccess { _ in }
        }.store(in: &subscriptions)

        chatPanel.onClose = { [weak self] in self?.pet.setChatGap(0) }
        chatPanel.onSend = { [weak self] text in
            guard let self else { return }
            if self.researchMode { self.askResearch(text) } else { self.brain.chat(text) }
        }
        research.onDailyMessage = { [weak self] text in self?.brain.chat(text, fromOwner: false) }

        settingsWindow.onModelChange = { [weak self] in
            guard let self else { return }
            let model = self.settings.selectedModel
            self.pet.reload(model: model)
            self.film.reload(model: model)
        }
        settingsWindow.onTestReminders = { [weak self] in self?.reminders.fireAllForTesting() }
        settingsWindow.onRunDailyTasks = { [weak self] in self?.runDailyTasks() }
        settingsWindow.onDigestMemories = { [weak self] report in self?.brain.mind.digestNow(done: report) }
        settingsWindow.onPreviewMeow = { [weak self] in self?.pet.meow(.meow) }
        settingsWindow.onPreviewSpeech = { [weak self] outcome in self?.pet.speaker.preview(outcome: outcome) }
        settingsWindow.onCheckSpeechBalance = { [weak self] report in
            self?.speechBalance.refresh { result in
                switch result {
                case .success(let b): report(b.detail)
                case .failure(let error): report("✗ " + error.localizedDescription)
                }
            }
        }
        settingsWindow.onCheckWeather = { [weak self] report in self?.weather.check(force: true, report: report) }
        settingsWindow.onCheckCalendar = { [weak self] report in
            self?.calendar.requestAccess { _ in self?.calendar.check(force: true, report: report) }
        }

        settings.$researchFigure.dropFirst().removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.pet.setResearchFigure(ResearchFigure.url) }  // after didSet stored it
        }.store(in: &subscriptions)
        settings.$petScale.dropFirst().removeDuplicates().sink { [weak self] in self?.pet.scale = CGFloat($0) }.store(in: &subscriptions)
        settings.$speech.dropFirst().removeDuplicates().filter { !$0 }.sink { [weak self] _ in self?.pet.speaker.stop() }
            .store(in: &subscriptions)
        // The local voice runs while reading aloud uses it (after the settings changed: once they are stored).
        Publishers.CombineLatest3(settings.$speech, settings.$speechEngine, settings.$cloudSpeechBaseURL)
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.localVoice.update() }.store(in: &subscriptions)
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.localVoice.stop() }
        }
        settings.$petLayer.dropFirst().sink { [weak self] layer in
            self?.pet.setLayer(layer)
            if layer != .top { self?.climber.jumpDown() }  // on a window it would be hidden behind other windows
        }.store(in: &subscriptions)
        settings.$hotKey.removeDuplicates().sink { [weak self] preset in
            if self?.hotKey.register(preset) == false { NSLog("Hot key %@ is not available", preset.title) }
        }.store(in: &subscriptions)

        music.onPlayingChange = { [weak self] playing in self?.musicChanged(playing) }
        music.onBeat = { [weak self] strength in
            self?.pet.beat(strength)
            self?.mischief.musicBeat(strength)
        }
        settings.$followBeat.removeDuplicates().sink { [weak self] in self?.music.followBeat = $0 }.store(in: &subscriptions)
        settings.$danceToMusic.removeDuplicates().sink { [weak self] on in
            guard let self else { return }
            if on { self.music.start() } else { self.music.stop() }
        }.store(in: &subscriptions)

        settings.$wander.removeDuplicates().sink { [weak self] level in self?.scheduleWander(level) }.store(in: &subscriptions)
        mischief.canAct = { [weak self] in self?.mayActOnItsOwn ?? false }
        mischief.reallyAsleep = { [weak self] in self?.brain.sleeping ?? false }
        mischief.perched = { [weak self] in self?.climber.ledge != nil || self?.iconVisits.perch != nil }
        iconVisits.canAct = { [weak self] in
            guard let self else { return false }
            return self.mayActOnItsOwn && !self.film.isLive && !self.approval.isVisible && Mischief.keyboardIdleSeconds >= 5
        }
        iconVisits.inFilm = { [weak self] in self?.film.isLive ?? false }
        iconVisits.visitInFilm = { [weak self] name in self?.film.visitIcon(name, arrived: true) }
        iconVisits.onIcons = { [weak self] icons in self?.film.icons = icons }
        iconVisits.willLeap = { [weak self] in self?.climber.ownerMoved() }
        settings.$iconPlay.removeDuplicates().sink { [weak self] on in self?.iconVisits.setEnabled(on) }.store(in: &subscriptions)
        mischief.canJoke = { [weak self] in
            guard let self else { return false }
            return self.pet.panel.isVisible && !self.researchMode && !self.chatPanel.isVisible && !self.brain.sleeping
                && !self.pet.dragging && PetBrain.idleSeconds < 120
        }
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.wanderIfDue()
                self?.mischief.tick()
                self?.runDailyTasksIfDue()  // covers a day change while the app keeps running
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        wanderTimer = timer

        installTestHooks()
        observeReturns()
        setUpFilm()

        // The screen saver: keep an installed copy current, and give it fresh names and tasks every minute.
        SaverInstaller.updateIfInstalled()
        Standby.write(nextNote: reminders.nextNote, nextEvent: calendar.nextEvent, balance: deepseekBalance.balance)
        let standby = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { Standby.write(nextNote: self?.reminders.nextNote, nextEvent: self?.calendar.nextEvent, balance: self?.deepseekBalance.balance) }
        }
        RunLoop.main.add(standby, forMode: .common)
        settingsWindow.onInstallSaver = { [weak self] in
            Standby.write(nextNote: self?.reminders.nextNote, nextEvent: self?.calendar.nextEvent, balance: self?.deepseekBalance.balance)
            return SaverInstaller.install()
                ? tr("已安装。请在“系统设置 → 屏幕保护程序”中选择 DeskPet。", "Installed. Choose DeskPet under System Settings → Screen Saver.")
                : tr("这个版本没有附带屏保，请用 build.sh 重新构建。", "This build has no screen saver; rebuild with build.sh.")
        }
        if BootIntro.dueThisBoot, ProcessInfo.processInfo.environment["DESKPET_DIR"] == nil {
            BootIntro.markPlayedThisBoot()
            playIntro()
        }

        // First launch without a key: open the model settings.
        if !Keychain.hasValue(account: "anthropic") && !Keychain.hasValue(account: "openai") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.settingsWindow.show(tab: .model) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        setPetVisible(true)
        return true
    }

    // MARK: PetWindowDelegate

    func petDidBecomeReady(mode: String) {
        pet.setResearch(researchMode)
        petReady = true
        if !greeted, !introPlaying {
            greeted = true
            // Right after the login intro the pet reports for duty; otherwise an ordinary hello.
            if bootIntro.playedThisLaunch { brain.welcomeBack() } else { brain.greet() }
            climber.ownerDropped()  // still standing on the window where it was left?
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.runDailyTasksIfDue() }
        }
    }

    // MARK: Desktop film

    private func setUpFilm() {
        film.canPlay = { [weak self] in self?.filmAllowed ?? false }
        film.screenForPet = { [weak self] in
            guard let self else { return nil }
            let f = self.pet.panel.frame
            let body = NSPoint(x: f.midX, y: self.pet.characterOrigin.y + self.pet.characterHeight / 2)
            return NSScreen.screens.first { $0.frame.contains(body) } ?? NSScreen.screens.first
        }
        film.menuBarIsDark = { [weak self] in
            self?.statusItem?.button?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]).map { $0 == .darkAqua }
        }
        film.onLiveChange = { [weak self] live in self?.filmLiveChanged(live) }
        film.onOpened = { [weak self] long in self?.filmOpened(long) }
        film.onVisit = { [weak self] kind, name, owner, arrived in self?.filmVisited(kind: kind, name: name, owner: owner, arrived: arrived) }
        film.onClick = { [weak self] area in self?.petDidClick(area: area, clickCount: 1) }
        film.onContextMenu = { [weak self] event, view in
            guard let self else { return }
            NSMenu.popUpContextMenu(self.petContextMenu(), with: event, for: view)
        }
        settings.$desktopFilm.removeDuplicates().sink { [weak self] on in
            guard let self else { return }
            self.film.setEnabled(on, model: on ? self.settings.selectedModel : nil)
        }.store(in: &subscriptions)
    }

    /// The film plays only while the owner is around and the pet is free: shown, not in research mode or a
    /// daily run (their answers need the pet's bubbles), not waiting for an approval, not held by the owner.
    private var filmAllowed: Bool {
        !petHidden && !researchMode && !dailyRunning && !introPlaying && awaySince == nil && !screenLocked
            && !approval.isVisible && !pet.dragging && pet.bubbles == PetWindowController.chatBubbles
    }

    /// The pet steps into the film (its window fades out, its words and motions go to the film) or back out.
    private func filmLiveChanged(_ live: Bool) {
        let panel = pet.panel
        if live {
            mischief.interrupt()
            iconVisits.interrupt()
            pet.cancelHop()
            chatPanel.dismiss()
            pet.standIn = { [weak self] fn, args in self?.film.perform(fn, args) }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.35
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    if self?.film.isLive == true { panel.orderOut(nil) }
                    panel.alphaValue = 1
                }
            })
        } else {
            pet.standIn = nil
            chatPanel.dismiss()  // it sat in the film
            guard !petHidden else { return }
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.35
                panel.animator().alphaValue = 1
            }
        }
    }

    /// The film's character got to a desktop icon (a file just put there, or one it chose) or peeks from behind a
    /// widget: its remark, as a subtitle. The Claude usage widget gets the real figure.
    private func filmVisited(kind: String, name: String, owner: String, arrived: Bool) {
        guard film.isLive else { return }
        let text: String
        if kind == "icon" {
            text = arrived ? DesktopItems.remark(onArrival: name) : DesktopItems.remark(visiting: name)
        } else {
            var percent: Int?
            if DesktopItems.widgetKind(owner: owner, name: name) == .claude, let usage = claudeUsage.refresh(),
               usage.quotaIsFresh(now: Date()), let used = usage.quota?.fiveHour?.usedPercent {
                percent = Int(used.rounded())
            }
            text = DesktopItems.remark(widgetOwner: owner, name: name, claudePercent: percent)
        }
        pet.meow(.mew, chance: 0.3)
        brain.consider(.event("在桌面影院里，" + (kind == "icon" ? "你跳到了桌面图标「\(name)」上" : "你从小组件「\(owner)\(name.isEmpty ? "" : " · " + name)」后面探出头来")
                              + "。（参考：\(text)）"))
    }

    /// After a full opening the pet greets the audience; after a short one it may give a little nod.
    private func filmOpened(_ long: Bool) {
        guard film.isLive, !brain.sleeping else { return }
        guard long else {
            if Double.random(in: 0..<1) < 0.4 { pet.play(.happy) }
            return
        }
        pet.meow(.trill, chance: 0.6)
        brain.consider(.event("桌面影院开始放映：桌面空了出来，你走进画面成了电影的主角，镜头对准了你"))
    }

    @objc private func toggleDesktopFilm() { settings.desktopFilm.toggle() }

    // MARK: Coming back

    /// Away: the display sleeps, the screen locks or the screen saver starts. Back: the display wakes, the screen
    /// is unlocked or the screen saver stops — while the screen is still locked, the intro waits for the unlock.
    private func observeReturns() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.wentAway() }
        }
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cameBack() }
        }
        let dn = DistributedNotificationCenter.default()
        let events: [(String, Bool?)] = [("com.apple.screensaver.didstart", nil), ("com.apple.screensaver.didstop", nil),
                                         ("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)]
        for (name, locked) in events {
            let away = name.hasSuffix("didstart") || locked == true
            dn.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if let locked { self?.screenLocked = locked }
                    if away { self?.wentAway() } else { self?.cameBack(unlocked: locked == false) }
                }
            }
        }
    }

    private func wentAway() {
        if awaySince == nil { awaySince = Date() }
        returnWork?.cancel()
    }

    private func cameBack(unlocked: Bool = false) {
        guard let since = awaySince, !screenLocked else { return }
        returnWork?.cancel()
        // A moment later: a lock screen that follows the screen saver is reported just after it stops. After an
        // unlock nothing else follows, so the intro starts at once (its bar takes over from the password field).
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.screenLocked, self.awaySince != nil else { return }
            self.awaySince = nil
            guard self.settings.bootIntro, self.settings.introOnReturn,
                  Date().timeIntervalSince(since) >= Self.minimumAway else { return }
            self.brain.wakeQuietly()
            self.playIntro()
        }
        returnWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (unlocked ? 0.05 : 1.0), execute: work)
    }

    /// A calendar event from the chat is written at once; macOS decides through its Calendars permission.
    private func addEvent(_ request: EventRequest) {
        let add = { [weak self] in
            guard let self else { return }
            self.pet.say(self.calendar.add(request), kind: "memory")
        }
        if CalendarWatcher.authorized { add() } else { calendar.requestAccess { [weak self] granted in
            if granted { add() } else { self?.pet.say(CalendarWatcher.statusText, kind: "error") }
        } }
    }

    /// An agent task starts at once, with full access: macOS and dsh decide what it may do.
    private func startAgentTask(_ task: String) {
        Task { @MainActor in
            do {
                let report = try await self.agent.run(task)
                self.brain.agentFinished(task: task, report: report)
            } catch {
                self.pet.play(.sad)
                self.pet.say(error.localizedDescription, kind: "error", aloud: false)
            }
        }
    }

    /// The login intro on every screen; afterwards the pet waves, meows and says hello.
    @objc private func playIntro() {
        guard !introPlaying else { return }
        introPlaying = true
        chatPanel.dismiss()
        bootIntro.play { [weak self] in
            guard let self else { return }
            self.introPlaying = false
            if self.petReady, !self.greeted { self.petDidBecomeReady(mode: "") } else { self.brain.welcomeBack() }
        }
    }

    /// A click on the head pets the pet; only a click that triggers nothing else (the body) opens the chat box.
    func petDidClick(area: String, clickCount: Int) {
        switch area {
        case "head":
            if clickCount == 1, !mischief.caught(), !mischief.sulkAtPat() { brain.pat() }
        case "body":
            _ = mischief.caught()
            openChat()
        case let a where a.hasPrefix("answer:"): showMessageList(String(a.dropFirst("answer:".count)))
        default: break  // a bubble (dismissed by the page itself)
        }
    }

    func petDidMove() {
        mischief.ownerMoved()
        climber.ownerMoved()
        iconVisits.ownerMoved()
    }

    func petDidDrop() {
        climber.ownerDropped()
        if climber.ledge == nil { iconVisits.ownerDropped() }  // or on top of a desktop icon
    }

    func petContextMenu() -> NSMenu {
        let menu = NSMenu()
        addItems(to: menu)
        menu.delegate = contextMenuWatch
        return menu
    }

    /// Whether the pet's context menu is open; the pet does not move on its own meanwhile (the menu would be left
    /// behind or, in the film, carried along).
    private var contextMenuOpen: Bool { contextMenuWatch.open }
    private let contextMenuWatch = ContextMenuWatch()

    // MARK: Actions

    @objc func openChat() {
        showChat(activating: false)
    }

    /// `activating` is used by the global shortcut: with no click on the panel, the app has to become
    /// active to receive keystrokes; the previous app is reactivated when the box closes.
    private func showChat(activating: Bool) {
        mischief.interrupt()
        let name = settings.petName
        let wasOpen = chatPanel.isVisible
        if petHidden { setPetVisible(true) }
        let placeholder = researchMode
            ? tr("科研模式：输入问题…（↩ 发送，Esc 关闭）", "Research mode: ask a question… (↩ send, Esc close)")
            : tr("和\(name)说点什么…（↩ 发送，Esc 关闭）", "Say something to \(name)… (↩ send, Esc close)")
        if film.isLive, let (point, screen) = film.chatPoint {
            // The click that led here went to the desktop (Finder), so the box has to activate the app for keys.
            chatPanel.present(centeredAt: point, on: screen, placeholder: placeholder, activating: true)
        } else {
            chatPanel.present(below: pet.panel, feetY: pet.feetY, placeholder: placeholder, activating: activating)
            // Bubbles below the character would sit under the box: they move down while it is open.
            pet.setChatGap(pet.bubblesBelow ? chatPanel.frame.height + 10 : 0)
        }
        if !wasOpen { pet.play(.wave) }
    }

    private func toggleChatFromHotKey() {
        if chatPanel.isVisible { chatPanel.dismiss() } else { showChat(activating: true) }
    }

    // MARK: Research mode

    @objc private func toggleResearchMode() { setResearchMode(!researchMode) }

    private func setResearchMode(_ on: Bool) {
        guard on != researchMode else { return }
        if on { film.interrupt() }  // research answers need the pet's own bubbles
        researchMode = on
        mischief.interrupt()
        pet.cancelHop()
        pet.setResearch(on)
        pet.setBubbles(on ? PetWindowController.researchBubbles : PetWindowController.chatBubbles)
        if on {
            researchConversationID = nil
            pet.play(.nod)
            let mode = settings.researchModeName.trimmingCharacters(in: .whitespaces)
            pet.say(mode.isEmpty
                ? tr("进入科研模式啦，有什么问题尽管问～完整回答都会存进消息列表。",
                     "Research mode on — ask away! Full answers are kept in the message list.")
                : tr("\(mode) 模式启动。全部算力已切换至科研任务，请提出问题；完整回答存入消息列表。",
                     "\(mode) mode engaged. All capacity is on research; ask away. Full answers go to the message list."))
            showChat(activating: false)
        } else {
            if engine.isBusy { engine.cancel() }
            pet.play(.wave)
            let mode = settings.researchModeName.trimmingCharacters(in: .whitespaces)
            pet.say(mode.isEmpty ? tr("退出科研模式，休息一下吧～", "Research mode off. Time for a break~")
                                 : tr("\(mode) 模式解除，回到日常状态。休息一下吧～", "\(mode) mode released. Back to everyday mode — take a break~"))
        }
        if chatPanel.isVisible { showChat(activating: false) }  // refresh the placeholder
    }

    @objc private func toggleResearchSearch() {
        engine.webSearch.toggle()
        pet.say(engine.webSearch ? tr("好，需要时我会联网查资料～", "Okay, I'll search the web when needed~")
                                 : tr("好，先不联网，直接回答会快很多～", "Okay, answering without searching — much faster~"))
    }

    @objc private func newResearchTopic() {
        researchConversationID = nil
        pet.say(tr("好的，开始一个新话题～", "Okay, a new topic~"))
    }

    /// One research question from the chat box; the answer streams into an answer bubble.
    private func askResearch(_ text: String) {
        guard !engine.isBusy else {
            pet.say(tr("还在查上一个问题，稍等一下喵～", "Still working on the last question~"))
            return
        }
        pet.say(text, fromUser: true)
        Task { @MainActor in
            researchConversationID = await presentResearchTurn(text, in: researchConversationID) ?? researchConversationID
        }
    }

    /// Runs one research turn and shows it as the pet's status and answer bubbles.
    /// Returns the conversation id once the turn has ended (nil if it could not start).
    private func presentResearchTurn(_ text: String, in conversationID: String?, title: String? = nil, forceTools: Bool = false,
                                     statusPrefix: String = "") async -> String? {
        pet.setStatus(statusPrefix + tr("思考中", "Thinking"))
        pet.play(.think)
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            var answerShown = false
            var current = conversationID
            var events = ResearchEngine.Events()
            events.onStart = { id, _, _ in current = id }
            events.onStatus = { [weak self] _, status in if !answerShown { self?.pet.setStatus(statusPrefix + status) } }
            events.onDelta = { [weak self] aid, piece in
                guard let self else { return }
                if !answerShown {
                    answerShown = true
                    self.pet.setStatus(nil)
                    self.pet.beginAnswer(aid)
                }
                self.pet.answerDelta(aid, piece)
            }
            events.onFinish = { [weak self] aid, text, _ in
                guard let self else { return }
                if !answerShown { self.pet.setStatus(nil); self.pet.beginAnswer(aid) }
                self.pet.finishAnswer(aid, text, conversationID: current ?? "")
                self.pet.play(.happy)
            }
            events.onFail = { [weak self] aid, message in
                guard let self else { return }
                self.pet.setStatus(nil)
                if answerShown { self.pet.failAnswer(aid) }
                self.pet.play(.sad)
                self.pet.say(message, kind: "error")
            }
            events.onEnd = { continuation.resume(returning: current) }
            if engine.ask(text, in: conversationID, title: title, forceTools: forceTools, events: events) == nil {
                pet.setStatus(nil)
                continuation.resume(returning: nil)
            }
        }
    }

    // MARK: Daily tasks

    private var dailyRunning = false

    private static func dayStamp(_ date: Date = Date()) -> String {
        ReminderRules.dayStamp(date, .current)
    }

    /// Whether a model can be called without first asking the user for a key.
    private var providerConfigured: Bool { Providers.configured(settings) }

    /// The first launch (or the first use) of each day runs the daily tasks once.
    private func runDailyTasksIfDue() {
        guard settings.dailyTasksEnabled, !settings.dailyTaskList.isEmpty, settings.dailyLastRun != Self.dayStamp(),
              !dailyRunning, !engine.isBusy, !brain.sleeping, PetBrain.idleSeconds < 120, providerConfigured else { return }
        runDailyTasks()
    }

    @objc private func runDailyTasksNow() { runDailyTasks() }

    private func runDailyTasks() {
        let tasks = settings.dailyTaskList
        guard !tasks.isEmpty else {
            pet.say(tr("还没有设置每日任务，可以在 设置 → 每日任务 里添加～", "No daily tasks yet — add some under Settings → Daily tasks~"))
            return
        }
        guard !dailyRunning, !engine.isBusy else {
            pet.say(tr("我正在查别的东西，等一下哦～", "I'm busy looking something up, one moment~"))
            return
        }
        film.interrupt()  // the answers need the pet's own bubbles
        dailyRunning = true
        settings.dailyLastRun = Self.dayStamp()
        pet.cancelHop()
        pet.setBubbles(PetWindowController.researchBubbles)
        pet.play(.wave)
        pet.say(tr("我先帮你完成今天的 \(tasks.count) 项每日任务～", "Let me run today's \(tasks.count) daily task(s) first~"))

        let now = Date()
        let parts = Calendar.current.dateComponents([.month, .day], from: now)
        let title = tr("每日简报 · \(parts.month ?? 0)月\(parts.day ?? 0)日",
                       "Daily brief · " + now.formatted(Date.FormatStyle().month(.abbreviated).day().locale(L10n.locale)))
        let today = now.formatted(Date.FormatStyle(date: .complete, time: .shortened).locale(L10n.locale))
        Task { @MainActor in
            var conversationID: String?
            for (i, task) in tasks.enumerated() {
                let prompt = """
                【每日任务】现在是 \(today)。请完成：\(task)
                要求：先用检索工具获取最新信息（新闻用 search_news，行情用 get_stock_quotes，需要细节时用 fetch_webpage 阅读原文）；\
                用 3–6 条要点呈现，每条附来源链接；总字数不超过 400 字；只陈述检索结果中有依据的内容。
                """
                let prefix = tr("每日任务 \(i + 1)/\(tasks.count) · ", "Daily task \(i + 1)/\(tasks.count) · ")
                conversationID = await presentResearchTurn(prompt, in: conversationID, title: title, forceTools: true, statusPrefix: prefix) ?? conversationID
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
            dailyRunning = false
            pet.play(.happy)
            pet.say(tr("今天的任务完成啦，完整内容在消息列表的「\(title)」里～", "All done! The full brief is in the message list: “\(title)”."))
        }
    }

    /// The pointer played above the pet's head: it rises up and reaches for it with both forepaws, then jumps at it.
    func petTeased() {
        pet.play(.grab)
        pet.meow(.trill, chance: 0.5)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self, !self.pet.dragging, !self.pet.hopping, self.pet.standIn == nil else { return }
            self.pet.bounce()
        }
    }

    /// Back to the small bubble area once the last answer bubble has gone (outside research mode).
    func petAnswersCleared() {
        if !researchMode && !dailyRunning { pet.setBubbles(PetWindowController.chatBubbles) }
    }

    /// Test runs (DESKPET_DIR set) accept commands as distributed notifications, so that UI tests do not
    /// need to synthesise keystrokes: "research-on", "research-off", "ask:<text>".
    private func installTestHooks() {
        guard ProcessInfo.processInfo.environment["DESKPET_DIR"] != nil else { return }
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("local.deskpet.test"), object: nil, queue: .main) { [weak self] note in
            let command = note.object as? String ?? ""
            MainActor.assumeIsolated {
                guard let self else { return }
                NSLog("DeskPet test hook: %@", command)
                if command == "research-on" { self.setResearchMode(true) }
                else if command == "research-off" { self.setResearchMode(false) }
                else if command.hasPrefix("ask:") { self.chatPanel.onSend?(String(command.dropFirst(4))) }
                else if command == "daily" { self.runDailyTasks() }
                else if command.hasPrefix("mischief:") { self.mischief.trigger(String(command.dropFirst(9))) }
                else if command == "pat" { self.petDidClick(area: "head", clickCount: 1) }
                else if command == "climb" { self.climber.climbNow() }
                else if command == "usage" { self.reportClaudeUsage() }
                else if command == "intro" { self.playIntro() }
                else if command == "away" { self.awaySince = Date().addingTimeInterval(-Self.minimumAway - 1) }
                else if command == "back" { self.cameBack() }
                else if command == "down" { self.climber.jumpDown() }
                // Desktop icons: a visit now (of the pet's own accord, or to a named icon as if it had just arrived), leave.
                else if command == "icons-visit" { self.iconVisits.visitNow() }
                else if command.hasPrefix("icons-new:") { self.iconVisits.visitNow(arrived: true, name: String(command.dropFirst(10))) }
                else if command == "icons-leave" { self.iconVisits.leave(jump: true) }
                else if command == "icons-report", let dir = ProcessInfo.processInfo.environment["DESKPET_DIR"] {
                    try? self.iconVisits.report.write(toFile: dir + "/icons.txt", atomically: true, encoding: .utf8)
                }
                else if command == "tease" { self.petTeased() }
                else if command.hasPrefix("act:") { self.pet.play(PetMotion(rawValue: String(command.dropFirst(4))) ?? .idle) }
                else if command.hasPrefix("meow:") { self.pet.meow(MeowKind(rawValue: String(command.dropFirst(5))) ?? .meow) }
                // Reading aloud: a bubble of the pet, and how the last one was spoken (DESKPET_DIR/speech.txt).
                else if command.hasPrefix("say:") { self.pet.say(String(command.dropFirst(4))) }
                else if command.hasPrefix("agent-report:") { self.brain.agentFinished(task: "test", report: String(command.dropFirst(13))) }
                else if command == "settings" { self.settingsWindow.show() }
                // The inner life: consolidate the chat now, think (of the pet's own accord, after a return, about a
                // follow-up), run the minute's tick, and its state (DESKPET_DIR/mind.txt).
                else if command == "digest" { self.brain.mind.digestNow { NSLog("DeskPet digest: %@", $0) } }
                else if command == "think" { self.brain.mind.think(.idle) }
                else if command.hasPrefix("think-return:") { self.brain.mind.think(.returned(minutes: Int(command.dropFirst(13)) ?? 60)) }
                else if command == "think-follow" { self.brain.mind.think(.followUp) }
                else if command == "mind-tick" { self.brain.mind.tick() }
                // A reminder of the owner's, due in the given seconds: "remind:<seconds>:<text>".
                else if command.hasPrefix("remind:") {
                    let parts = command.dropFirst(7).split(separator: ":", maxSplits: 1)
                    if parts.count == 2, let seconds = Double(parts[0]) {
                        MemoryStore.shared.addReminder(String(parts[1]), at: Date().addingTimeInterval(seconds))
                    }
                }
                else if command == "look" { ScreenWatcher.shared.look { NSLog("DeskPet look: %@", $0) } }
                else if command == "mind-report", let dir = ProcessInfo.processInfo.environment["DESKPET_DIR"] {
                    try? self.brain.mind.report.write(toFile: dir + "/mind.txt", atomically: true, encoding: .utf8)
                }
                else if command == "speech-balance" { self.reportSpeechBalance() }
                else if command == "music-report", let dir = ProcessInfo.processInfo.environment["DESKPET_DIR"] {
                    try? (self.music.report + " grooving=\(self.pet.grooving ? 1 : 0)").write(toFile: dir + "/music.txt", atomically: true, encoding: .utf8)
                }
                else if command == "speech-report", let dir = ProcessInfo.processInfo.environment["DESKPET_DIR"] {
                    try? (self.pet.speaker.report + "\trevealed=\(self.pet.speaker.revealed)\tcached=\(self.pet.speaker.cacheHits)")
                        .write(toFile: dir + "/speech.txt", atomically: true, encoding: .utf8)
                }
                // The desktop film without changing the stored setting: on, forced live / still / back to the desktop.
                else if command == "film-on" { self.film.setEnabled(true, model: self.settings.selectedModel) }
                else if command == "film-off" { self.film.setEnabled(false, model: nil) }
                else if command == "film-live" { self.film.forced = true }
                else if command == "film-still" { self.film.forced = false }
                else if command == "film-auto" { self.film.forced = nil }
                else if command.hasPrefix("film-click:") { self.petDidClick(area: String(command.dropFirst(11)), clickCount: 1) }
                // A point on the film's character, in screen coordinates (DESKPET_DIR/film.txt), to aim real clicks at.
                else if command == "film-target", let dir = ProcessInfo.processInfo.environment["DESKPET_DIR"] {
                    self.film.characterPoint { point in
                        let text = (point.map { "\(Int($0.x)) \(Int($0.y))" } ?? "none")
                            + " left=\(self.film.caught.left) right=\(self.film.caught.right)"
                        try? text.write(toFile: dir + "/film.txt", atomically: true, encoding: .utf8)
                    }
                }
            }
        }
    }

    // MARK: Message list

    @objc private func openMessageList() { showMessageList(nil) }

    @objc private func openConversation(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { showMessageList(id) }
    }

    private func showMessageList(_ conversationID: String?) {
        chatPanel.dismissKeepingFocus()
        research.show(conversationID: conversationID)
    }

    /// Limits and usage from the Claude Usage Widget, and a button to have the pet read them out.
    private func claudeUsageItem(_ usage: ClaudeUsageSnapshot) -> NSMenuItem {
        let item = NSMenuItem(title: tr("Claude 用量", "Claude usage"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for line in ClaudeUsage.summaryLines(usage, now: Date()) {
            let i = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            i.isEnabled = false
            submenu.addItem(i)
        }
        submenu.addItem(.separator())
        let report = NSMenuItem(title: tr("让桌宠报告一下", "Have the pet report"), action: #selector(reportClaudeUsage), keyEquivalent: "")
        report.target = self
        submenu.addItem(report)
        item.submenu = submenu
        return item
    }

    private func deepseekBalanceItem() -> NSMenuItem {
        let b = deepseekBalance.balance
        let item = NSMenuItem(title: tr("DeepSeek 余额", "DeepSeek balance") + (b.map { "：\($0.short)" } ?? ""), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let lines = b.map { $0.lines + [($0.available ? tr("可正常调用", "Usable") : tr("余额不足，无法调用", "Too low to call the API"))] }
            ?? [tr("尚未获取", "Not fetched yet")]
        for line in lines {
            let i = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            i.isEnabled = false
            submenu.addItem(i)
        }
        submenu.addItem(.separator())
        let report = NSMenuItem(title: tr("让桌宠报告一下", "Have the pet report"), action: #selector(reportDeepSeekBalance), keyEquivalent: "")
        report.target = self
        submenu.addItem(report)
        let open = NSMenuItem(title: tr("打开充值页面", "Open the top-up page"), action: #selector(openDeepSeekTopUp), keyEquivalent: "")
        open.target = self
        submenu.addItem(open)
        item.submenu = submenu
        return item
    }

    @objc private func reportDeepSeekBalance() {
        pet.setStatus(tr("查询余额", "Checking the balance"))
        deepseekBalance.refresh { [weak self] result in
            guard let self else { return }
            self.pet.setStatus(nil)
            switch result {
            case .success(let b):
                self.pet.play(b.isLow ? .surprised : .nod)
                let state = b.available ? (b.isLow ? tr("有点少了，记得充值～", "running low, top up soon~") : tr("还够用。", "plenty for now."))
                                        : tr("已经不够调用了，需要充值。", "too low to call the API; please top up.")
                self.pet.say(tr("DeepSeek 余额：", "DeepSeek balance: ") + b.lines.joined(separator: "；") + tr("，", ", ") + state, ms: 15000)
            case .failure(let error):
                self.pet.play(.sad)
                self.pet.say(error.localizedDescription, kind: "error")
            }
        }
    }

    private func claudeCostItem() -> NSMenuItem {
        let watcher = ClaudeCostWatcher.shared
        let title = watcher.cost.map { _ in watcher.lines.last ?? "" } ?? ""
        let item = NSMenuItem(title: tr("Claude API 花费", "Claude API spending") + (title.isEmpty ? "" : "：" + title), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for line in watcher.lines {
            let i = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            i.isEnabled = false
            submenu.addItem(i)
        }
        if settings.claudeCreditBase <= 0 {
            let hint = NSMenuItem(title: tr("在“设置 → 模型”中填入 Console 显示的余额后可估算剩余", "Enter the Console's balance under Settings → Model to estimate what is left"),
                                  action: nil, keyEquivalent: "")
            hint.isEnabled = false
            submenu.addItem(hint)
        }
        submenu.addItem(.separator())
        let report = NSMenuItem(title: tr("让桌宠报告一下", "Have the pet report"), action: #selector(reportClaudeCost), keyEquivalent: "")
        report.target = self
        submenu.addItem(report)
        let open = NSMenuItem(title: tr("打开 Claude Console 结算页", "Open Claude Console billing"), action: #selector(openClaudeBilling), keyEquivalent: "")
        open.target = self
        submenu.addItem(open)
        item.submenu = submenu
        return item
    }

    @objc private func reportClaudeCost() {
        pet.setStatus(tr("查询 Claude 花费", "Checking Claude spending"))
        ClaudeCostWatcher.shared.refresh { [weak self] result in
            guard let self else { return }
            self.pet.setStatus(nil)
            switch result {
            case .success:
                self.pet.play(.nod)
                self.pet.say(tr("Claude API：", "Claude API: ") + ClaudeCostWatcher.shared.lines.joined(separator: tr("；", "; ")) + tr("。", "."), ms: 15000)
            case .failure(let error):
                self.pet.play(.sad)
                self.pet.say(error.localizedDescription, kind: "error")
            }
        }
    }

    @objc private func openClaudeBilling() {
        if let url = URL(string: ClaudeCost.consoleURL) { NSWorkspace.shared.open(url) }
    }

    @objc private func openDeepSeekTopUp() {
        if let url = URL(string: "https://platform.deepseek.com/top_up") { NSWorkspace.shared.open(url) }
    }

    private func speechBalanceItem() -> NSMenuItem {
        let b = speechBalance.balance, retired = speechBalance.retired
        let value = retired ? tr("：在控制台查看", ": see the console") : b.map { "：\($0.short)" } ?? ""
        let item = NSMenuItem(title: tr("语音余额", "Voice balance") + value, action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let text = retired ? tr("硅基流动已停用余额查询接口", "SiliconFlow has retired its balance endpoint")
            : b.map { tr("硅基流动 ", "SiliconFlow ") + $0.detail } ?? tr("尚未获取", "Not fetched yet")
        let line = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        line.isEnabled = false
        submenu.addItem(line)
        submenu.addItem(.separator())
        if !retired {
            let report = NSMenuItem(title: tr("让桌宠报告一下", "Have the pet report"), action: #selector(reportSpeechBalance), keyEquivalent: "")
            report.target = self
            submenu.addItem(report)
        }
        let open = NSMenuItem(title: tr("打开硅基流动控制台", "Open the SiliconFlow console"), action: #selector(openSpeechConsole), keyEquivalent: "")
        open.target = self
        submenu.addItem(open)
        item.submenu = submenu
        return item
    }

    @objc private func reportSpeechBalance() {
        pet.setStatus(tr("查询余额", "Checking the balance"))
        speechBalance.refresh { [weak self] result in
            guard let self else { return }
            self.pet.setStatus(nil)
            switch result {
            case .success(let b):
                self.pet.play(.nod)
                self.pet.say(tr("语音余额（硅基流动）：", "Voice balance (SiliconFlow): ") + b.detail, ms: 15000)
            case .failure(let error):
                self.pet.play(.sad)
                self.pet.say(error.localizedDescription, kind: "error")
            }
        }
    }

    @objc private func openSpeechConsole() {
        if let url = CloudSpeechBalance.console(baseURL: settings.cloudSpeechBaseURL) { NSWorkspace.shared.open(url) }
    }

    @objc private func reportClaudeUsage() {
        guard let usage = claudeUsage.refresh() else { return }
        pet.play(.nod)
        pet.say(ClaudeUsage.report(usage, now: Date()), ms: 15000)
    }

    /// Recent conversations, newest first, plus the full list.
    private func fillMessages(_ messagesMenu: NSMenu) {
        messagesMenu.removeAllItems()
        let open = NSMenuItem(title: tr("打开消息列表…", "Open message list…"), action: #selector(openMessageList), keyEquivalent: "")
        open.target = self
        messagesMenu.addItem(open)
        messagesMenu.addItem(.separator())
        let all = ConversationStore.shared.list()
        let header = NSMenuItem(title: tr("最近的对话", "Recent conversations"), action: nil, keyEquivalent: "")
        header.isEnabled = false
        messagesMenu.addItem(header)
        for summary in all.prefix(12) {
            let icon = summary.kind == .daily ? "💬 " : "📚 "
            let title = icon + (summary.title.count > 28 ? String(summary.title.prefix(28)) + "…" : summary.title)
            let i = NSMenuItem(title: title, action: #selector(openConversation(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = summary.id
            i.toolTip = L10n.dateTime(summary.updated)
            messagesMenu.addItem(i)
        }
    }
    @objc private func openSettings() { settingsWindow.show() }
    @objc private func openReminderSettings() { settingsWindow.show(tab: .reminders) }
    @objc private func togglePet() { setPetVisible(petHidden) }

    @objc private func selectLayer(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let layer = PetLayer(rawValue: raw) { settings.petLayer = layer }
    }
    @objc private func selectAgentEffort(_ sender: NSMenuItem) {
        if let value = sender.representedObject as? String { settings.agentEffort = value }
    }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func toggleLidAwake() {
        LidSleep.set(awake: !LidSleep.staysAwake) { [weak self] in self?.pet.say($0, kind: "memory") }
    }

    @objc private func toggleFocus() {
        if reminders.focusRunning {
            reminders.stopFocus()
            pet.say(tr("好的，专注计时已停止。", "Okay, focus timer stopped."))
        } else {
            reminders.startFocus()
            pet.play(.nod)
            pet.say(tr("开始专注 25 分钟！我会安静陪着你～", "25 minutes of focus, starting now! I'll keep quiet~"))
        }
    }

    // MARK: Music

    /// Music started: the pet's mind decides whether to sway to it and whether to say something (PetMind.onDance).
    /// It stopped: the swaying ends, and after two minutes or more the pet may say something about it.
    private func musicChanged(_ playing: Bool) {
        brain.musicPlaying = playing
        if playing {
            musicStarted = Date()
            brain.consider(.music)
            return
        }
        pet.setGrooving(false)
        mischief.musicChanged(false)
        if let start = musicStarted, Date().timeIntervalSince(start) >= 120 {
            brain.consider(.musicStopped(minutes: Int(Date().timeIntervalSince(start) / 60)))
        }
        musicStarted = nil
    }

    // MARK: Wandering

    private func scheduleWander(_ level: WanderLevel) {
        nextWander = level.interval.map { Date().addingTimeInterval(.random(in: $0)) } ?? .distantFuture
    }

    private func wanderIfDue() {
        guard Date() >= nextWander else { return }
        // Not while the owner is typing: the hop waits until a pause instead of being skipped.
        if Mischief.keyboardIdleSeconds < 20 {
            nextWander = Date().addingTimeInterval(.random(in: 30...90))
            return
        }
        scheduleWander(settings.wander)
        guard mayActOnItsOwn else { return }
        wander()
    }

    /// Only while the owner is around and nothing else is going on; never in research mode.
    private var mayActOnItsOwn: Bool {
        pet.panel.isVisible && !researchMode && !chatPanel.isVisible && !brain.sleeping && !brain.musicPlaying && !contextMenuOpen
            && !mischief.busy && !pet.hopping && !pet.dragging && PetBrain.idleSeconds < 120
    }

    @objc private func wanderNow() { wander() }

    @objc private func toggleIconVisit() {
        if iconVisits.perch != nil { iconVisits.leave(jump: true); return }
        if !iconVisits.visitNow() {
            pet.say(tr("现在够不着桌面图标：图标被窗口挡住了，或离菜单栏太近。", "No desktop icon in reach: they are under windows or too close to the menu bar."), ms: 5000)
        }
    }

    /// Hops to a random spot on the same screen, 160–520 pt away.
    private func wander() {
        guard pet.panel.isVisible, !pet.hopping, !pet.dragging else { return }
        if iconVisits.perch != nil { return }  // sitting on a desktop icon until the visit ends
        if climber.wander() { return }  // up onto a window, along it, or back down
        guard let area = (pet.panel.screen ?? NSScreen.main)?.visibleFrame else { return }
        let frame = pet.panel.frame
        // The window is wider than the character, so it may overhang the screen edge a little.
        let minX = area.minX - frame.width * 0.25, maxX = area.maxX - frame.width * 0.75
        guard maxX - minX > 200 else { return }
        var target = CGFloat.random(in: minX...maxX)
        let dx = target - frame.minX
        if abs(dx) < 160 { target = frame.minX + (dx < 0 ? -160 : 160) }
        if abs(target - frame.minX) > 520 { target = frame.minX + (target > frame.minX ? 520 : -520) }
        if target < minX || target > maxX { target = frame.minX - (target - frame.minX) }
        pet.wander(to: min(max(target, minX), maxX))
    }

    private func setPetVisible(_ visible: Bool) {
        petHidden = !visible
        if visible {
            if !film.isLive { pet.panel.orderFrontRegardless() }  // otherwise the pet is in the film
        } else {
            chatPanel.dismiss()
            pet.panel.orderOut(nil)
            film.interrupt()
        }
    }

    // MARK: Menus

    private func addItems(to menu: NSMenu) {
        @discardableResult
        func item(_ title: String, _ action: Selector, _ key: String = "") -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.target = self
            menu.addItem(i)
            return i
        }
        item(tr("和我聊天", "Chat"), #selector(openChat))
        let modeName = settings.researchModeName.trimmingCharacters(in: .whitespaces)
        item(modeName.isEmpty ? tr("科研模式", "Research mode") : tr("科研模式（\(modeName)）", "Research mode (\(modeName))"),
             #selector(toggleResearchMode)).state = researchMode ? .on : .off
        if researchMode {
            item(tr("开始新的科研话题", "New research topic"), #selector(newResearchTopic))
            item(tr("联网检索（较慢）", "Search the web (slower)"), #selector(toggleResearchSearch)).state = engine.webSearch ? .on : .off
        }
        if !researchMode { item(tr("去别处转转", "Hop somewhere else"), #selector(wanderNow)) }
        if !researchMode, settings.iconPlay, !film.isLive {
            item(iconVisits.perch == nil ? tr("去桌面图标上坐坐", "Go sit on a desktop icon") : tr("从图标上下来", "Get down from the icon"),
                 #selector(toggleIconVisit))
        }
        item(tr("执行每日任务", "Run daily tasks"), #selector(runDailyTasksNow))
        // Also reachable here: on notched displays the menu bar item may be hidden behind the notch.
        let messages = NSMenuItem(title: tr("消息列表", "Messages"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        fillMessages(submenu)
        messages.submenu = submenu
        menu.addItem(messages)
        if let usage = claudeUsage.refresh() { menu.addItem(claudeUsageItem(usage)) }
        if ClaudeCostWatcher.shared.shown {
            menu.addItem(claudeCostItem())
            ClaudeCostWatcher.shared.refresh(maxAge: 60)  // fresh for the next look
        }
        if DeepSeekBalanceWatcher.endpoint != nil {
            menu.addItem(deepseekBalanceItem())
            deepseekBalance.refresh(maxAge: 60)  // fresh for the next look
        }
        if SpeechBalanceWatcher.shown {
            menu.addItem(speechBalanceItem())
            speechBalance.refresh(maxAge: 60)
        }
        menu.addItem(.separator())
        item(reminders.focusRunning ? tr("停止专注计时", "Stop focus timer") : tr("开始专注 25 分钟", "Focus for 25 minutes"), #selector(toggleFocus))
        item(tr("合盖不休眠", "Stay awake with the lid closed"), #selector(toggleLidAwake)).state = LidSleep.staysAwake ? .on : .off
        item(tr("提醒设置…", "Reminders…"), #selector(openReminderSettings))
        item(tr("播放开机动画", "Play the login intro"), #selector(playIntro))
        item(tr("桌面影院（动态墙纸）", "Desktop film (live wallpaper)"), #selector(toggleDesktopFilm)).state = settings.desktopFilm ? .on : .off
        item(tr("设置…", "Settings…"), #selector(openSettings), ",")
        menu.addItem(.separator())
        let layer = NSMenuItem(title: tr("显示层级", "Window layer"), action: nil, keyEquivalent: "")
        let layers = NSMenu()
        for option in PetLayer.allCases {
            let i = NSMenuItem(title: option.title, action: #selector(selectLayer(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = option.rawValue
            i.state = settings.petLayer == option ? .on : .off
            layers.addItem(i)
        }
        layer.submenu = layers
        menu.addItem(layer)
        let effort = NSMenuItem(title: tr("执行代理推理强度", "Agent reasoning effort"), action: nil, keyEquivalent: "")
        let efforts = NSMenu()
        for option in DshAgent.efforts {
            let i = NSMenuItem(title: option.title, action: #selector(selectAgentEffort(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = option.value
            i.state = settings.agentEffort == option.value ? .on : .off
            efforts.addItem(i)
        }
        effort.submenu = efforts
        menu.addItem(effort)
        item(petHidden ? tr("显示桌宠", "Show pet") : tr("隐藏桌宠", "Hide pet"), #selector(togglePet))
        item(tr("退出", "Quit"), #selector(quit), "q")
    }

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "DeskPet")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        addItems(to: menu)
    }

    /// Text fields and the research page need an Edit menu for ⌘C / ⌘V / ⌘A.
    private func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: tr("退出 DeskPet", "Quit DeskPet"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: tr("关闭窗口", "Close Window"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: tr("最小化", "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        NSApp.mainMenu = main
    }
}

/// Earlier builds used the bundle identifier `local.deskpet`. Its settings are copied once into the
/// current domain (keys already set are kept), and launch at login is registered again for the new identifier.
enum LegacyDefaults {
    static let domain = "local.deskpet"

    static func migrate() {
        let defaults = UserDefaults.standard
        guard Bundle.main.bundleIdentifier != domain, !defaults.bool(forKey: "migratedLegacyDefaults") else { return }
        defaults.set(true, forKey: "migratedLegacyDefaults")
        guard let old = defaults.persistentDomain(forName: domain), !old.isEmpty else { return }
        for (key, value) in old where defaults.object(forKey: key) == nil { defaults.set(value, forKey: key) }
        if old["launchAtLogin"] as? Bool == true { _ = LoginItem.set(true) }
    }
}

/// One pet at a time: when two copies start together (e.g. two login items), the copy in an Applications folder
/// stays, and between equal candidates the earlier process. Test runs (DESKPET_DIR set) are exempt.
enum SingleInstance {
    static func claim() -> Bool {
        guard ProcessInfo.processInfo.environment["DESKPET_DIR"] == nil, let id = Bundle.main.bundleIdentifier else { return true }
        let me = NSRunningApplication.current
        func rank(_ app: NSRunningApplication) -> (Int, pid_t) {
            ((app.bundleURL?.path.contains("/Applications/") ?? false) ? 0 : 1, app.processIdentifier)
        }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id).filter { $0 != me && !$0.isTerminated }
        guard let best = others.min(by: { rank($0) < rank($1) }), rank(best) < rank(me) else { return true }
        NSLog("DeskPet is already running (pid %d); this copy quits", best.processIdentifier)
        return false
    }
}

/// Launch at login through SMAppService (macOS 13+).
enum LoginItem {
    static var enabled: Bool { SMAppService.mainApp.status == .enabled }

    /// The login item points at the copy that registered it; after the app moved (or a build copy registered
    /// it), the copy in an Applications folder registers again, so that login starts this copy.
    static func repairLocation() {
        let path = Bundle.main.bundlePath
        guard path.contains("/Applications/"), enabled, UserDefaults.standard.string(forKey: "loginItemPath") != path else { return }
        try? SMAppService.mainApp.unregister()
        if (try? SMAppService.mainApp.register()) != nil { UserDefaults.standard.set(path, forKey: "loginItemPath") }
    }

    static func set(_ on: Bool) -> Bool {
        do {
            if on {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else if SMAppService.mainApp.status != .notRegistered {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            NSLog("Login item change failed: %@", error.localizedDescription)
            return false
        }
    }
}

/// Follows whether the pet's context menu is open.
final class ContextMenuWatch: NSObject, NSMenuDelegate {
    private(set) var open = false
    func menuWillOpen(_ menu: NSMenu) { open = true }
    func menuDidClose(_ menu: NSMenu) { open = false }
}
