import AppKit
import Combine
import ServiceManagement

@MainActor
final class AppController: NSObject, NSApplicationDelegate, PetWindowDelegate, NSMenuDelegate {
    private let settings = AppSettings.shared
    private let pet = PetWindowController()
    private lazy var brain = PetBrain(pet: pet)
    private lazy var reminders = ReminderScheduler { [weak self] text, motion in
        self?.mischief.interrupt()  // e.g. back from a screen edge, so that the bubble is fully visible
        self?.brain.remind(text, motion: motion)
    }
    private lazy var weather = WeatherWatcher { [weak self] text, motion in self?.reminders.announce(text, motion: motion) }
    private lazy var claudeUsage = ClaudeUsageWatcher { [weak self] text, motion in self?.reminders.announce(text, motion: motion) }
    private let engine = ResearchEngine()
    private lazy var research = ResearchWindowController(engine: engine)
    private let settingsWindow = SettingsWindowController()
    private let chatPanel = ChatInputPanel()
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
    private let music = MusicMonitor()
    private var lastMusicRemark = Date.distantPast
    private var nextWander = Date.distantFuture

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        buildStatusItem()

        pet.delegate = self
        pet.setLayer(settings.petLayer)
        pet.show(model: settings.selectedModel, scale: settings.petScale)

        brain.onRemind = { [weak self] r in
            self?.reminders.add(minutes: r.minutes, text: r.text)
        }
        brain.start()
        reminders.start()
        weather.start()
        claudeUsage.start()

        chatPanel.onSend = { [weak self] text in
            guard let self else { return }
            if self.researchMode { self.askResearch(text) } else { self.brain.chat(text) }
        }
        research.onDailyMessage = { [weak self] text in self?.brain.chat(text) }

        settingsWindow.onModelChange = { [weak self] in
            guard let self else { return }
            self.pet.reload(model: self.settings.selectedModel)
        }
        settingsWindow.onTestReminders = { [weak self] in self?.reminders.fireAllForTesting() }
        settingsWindow.onRunDailyTasks = { [weak self] in self?.runDailyTasks() }
        settingsWindow.onPreviewMeow = { [weak self] in self?.pet.meow(.meow) }
        settingsWindow.onCheckWeather = { [weak self] report in self?.weather.check(force: true, report: report) }

        settings.$petScale.dropFirst().removeDuplicates().sink { [weak self] in self?.pet.scale = CGFloat($0) }.store(in: &subscriptions)
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
        mischief.perched = { [weak self] in self?.climber.ledge != nil }
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
        if !greeted {
            greeted = true
            brain.greet()
            climber.ownerDropped()  // still standing on the window where it was left?
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.runDailyTasksIfDue() }
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
    }

    func petDidDrop() { climber.ownerDropped() }

    func petContextMenu() -> NSMenu {
        let menu = NSMenu()
        addItems(to: menu)
        return menu
    }

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
        if !pet.panel.isVisible { setPetVisible(true) }
        let placeholder = researchMode
            ? tr("科研模式：输入问题…（↩ 发送，Esc 关闭）", "Research mode: ask a question… (↩ send, Esc close)")
            : tr("和\(name)说点什么…（↩ 发送，Esc 关闭）", "Say something to \(name)… (↩ send, Esc close)")
        chatPanel.present(below: pet.panel, placeholder: placeholder, activating: activating)
        if !wasOpen { pet.play(.wave) }
    }

    private func toggleChatFromHotKey() {
        if chatPanel.isVisible { chatPanel.dismiss() } else { showChat(activating: true) }
    }

    // MARK: Research mode

    @objc private func toggleResearchMode() { setResearchMode(!researchMode) }

    private func setResearchMode(_ on: Bool) {
        guard on != researchMode else { return }
        researchMode = on
        mischief.interrupt()
        pet.cancelHop()
        pet.setResearch(on)
        pet.setBubbles(on ? PetWindowController.researchBubbles : PetWindowController.chatBubbles)
        if on {
            researchConversationID = nil
            pet.play(.nod)
            pet.say(tr("进入科研模式啦，有什么问题尽管问～完整回答都会存进消息列表。",
                        "Research mode on — ask away! Full answers are kept in the message list."))
            showChat(activating: false)
        } else {
            if engine.isBusy { engine.cancel() }
            pet.play(.wave)
            pet.say(tr("退出科研模式，休息一下吧～", "Research mode off. Time for a break~"))
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
    private var providerConfigured: Bool {
        switch settings.provider {
        case .anthropic: return Keychain.hasValue(account: "anthropic")
        case .openai:
            let base = settings.openaiBaseURL
            return Keychain.hasValue(account: "openai") || base.contains("localhost") || base.contains("127.0.0.1")
        }
    }

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
                if command == "research-on" { self.setResearchMode(true) }
                else if command == "research-off" { self.setResearchMode(false) }
                else if command.hasPrefix("ask:") { self.chatPanel.onSend?(String(command.dropFirst(4))) }
                else if command == "daily" { self.runDailyTasks() }
                else if command.hasPrefix("mischief:") { self.mischief.trigger(String(command.dropFirst(9))) }
                else if command == "pat" { self.petDidClick(area: "head", clickCount: 1) }
                else if command == "climb" { self.climber.climbNow() }
                else if command == "usage" { self.reportClaudeUsage() }
                else if command == "down" { self.climber.jumpDown() }
                else if command.hasPrefix("meow:") { self.pet.meow(MeowKind(rawValue: String(command.dropFirst(5))) ?? .meow) }
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
    @objc private func togglePet() { setPetVisible(!pet.panel.isVisible) }

    @objc private func selectLayer(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let layer = PetLayer(rawValue: raw) { settings.petLayer = layer }
    }
    @objc private func quit() { NSApp.terminate(nil) }

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

    private func musicChanged(_ playing: Bool) {
        brain.musicPlaying = playing
        pet.setGrooving(playing)
        mischief.musicChanged(playing)
        // Now and then a word about the music (at most every 10 minutes).
        if playing, Date().timeIntervalSince(lastMusicRemark) > 600, Double.random(in: 0...1) < 0.4 {
            lastMusicRemark = Date()
            let lines = [tr("这首歌好好听～", "I like this song~"), tr("动次打次 ♪", "Boom, tss ♪"),
                         tr("一起摇摆吧～", "Let's groove~"), tr("听歌的时候效率会更高吗？", "Do you work better with music?")]
            pet.say(lines.randomElement()!)
        }
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
        pet.panel.isVisible && !researchMode && !chatPanel.isVisible && !brain.sleeping && !brain.musicPlaying
            && !mischief.busy && !pet.hopping && !pet.dragging && PetBrain.idleSeconds < 120
    }

    @objc private func wanderNow() { wander() }

    /// Hops to a random spot on the same screen, 160–520 pt away.
    private func wander() {
        guard pet.panel.isVisible, !pet.hopping, !pet.dragging else { return }
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
        if visible { pet.panel.orderFrontRegardless() } else { chatPanel.dismiss(); pet.panel.orderOut(nil) }
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
        item(tr("科研模式", "Research mode"), #selector(toggleResearchMode)).state = researchMode ? .on : .off
        if researchMode {
            item(tr("开始新的科研话题", "New research topic"), #selector(newResearchTopic))
            item(tr("联网检索（较慢）", "Search the web (slower)"), #selector(toggleResearchSearch)).state = engine.webSearch ? .on : .off
        }
        if !researchMode { item(tr("去别处转转", "Hop somewhere else"), #selector(wanderNow)) }
        item(tr("执行每日任务", "Run daily tasks"), #selector(runDailyTasksNow))
        // Also reachable here: on notched displays the menu bar item may be hidden behind the notch.
        let messages = NSMenuItem(title: tr("消息列表", "Messages"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        fillMessages(submenu)
        messages.submenu = submenu
        menu.addItem(messages)
        if let usage = claudeUsage.refresh() { menu.addItem(claudeUsageItem(usage)) }
        menu.addItem(.separator())
        item(reminders.focusRunning ? tr("停止专注计时", "Stop focus timer") : tr("开始专注 25 分钟", "Focus for 25 minutes"), #selector(toggleFocus))
        item(tr("提醒设置…", "Reminders…"), #selector(openReminderSettings))
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
        item(pet.panel.isVisible ? tr("隐藏桌宠", "Hide pet") : tr("显示桌宠", "Show pet"), #selector(togglePet))
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
