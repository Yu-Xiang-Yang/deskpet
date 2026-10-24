import AppKit
import CoreGraphics

/// The pet's behaviour: conversation with the persona, spontaneous remarks, petting reactions,
/// sleeping while the user is away.
final class PetBrain {
    private let settings = AppSettings.shared
    private let store = ConversationStore.shared
    private unowned let pet: PetWindowController
    /// Called when the model asks for a reminder.
    var onRemind: ((RemindRequest) -> Void)?
    var onOpenApp: ((String) -> Void)?
    var onAddEvent: ((EventRequest) -> Void)?
    var onAgentTask: ((String) -> Void)?
    var onClaudeTask: ((ClaudeTaskRequest) -> Void)?

    private var busy = false
    private var chatterTimer: Timer?
    private var idleTimer: Timer?
    private var chatterCount = 0
    private var lastChatter = Date()
    private(set) var sleeping = false
    /// While music plays the pet stays awake (the user is probably listening, not away).
    var musicPlaying = false {
        didSet { if musicPlaying && sleeping { wake() } }
    }

    init(pet: PetWindowController) {
        self.pet = pet
    }

    func start() {
        let idle = Timer(timeInterval: 10, repeats: true) { [weak self] _ in self?.checkIdle() }
        RunLoop.main.add(idle, forMode: .common)
        idleTimer = idle
        let chatter = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.maybeChatter() }
        RunLoop.main.add(chatter, forMode: .common)
        chatterTimer = chatter
    }

    // MARK: Prompt

    /// What the pet can do, with the owner's current settings, so that it can answer "what can you do" and point
    /// to the right place instead of promising what it cannot.
    var capabilitySection: String {
        func on(_ flag: Bool) -> String { flag ? "已开启" : "已关闭" }
        let r = settings.reminders
        var routines: [String] = []
        if r.mealsEnabled { routines.append("吃饭（\(r.mealTimes.joined(separator: "、"))）") }
        if r.workEnabled { routines.append("上下班（\(r.workStart)–\(r.workEnd)\(r.weekdaysOnly ? "，仅工作日" : "")）") }
        if r.sedentaryEnabled { routines.append("久坐（每 \(r.sedentaryMinutes) 分钟）") }
        if r.waterEnabled { routines.append("喝水（每 \(r.waterMinutes) 分钟）") }
        let mode = settings.researchModeName.trimmingCharacters(in: .whitespaces)
        let research = mode.isEmpty ? "科研模式" : "科研模式「\(mode)」"
        let city = settings.city.trimmingCharacters(in: .whitespaces)
        let tasks = settings.dailyTaskList
        let routineText: String = routines.isEmpty ? "当前均已关闭" : routines.joined(separator: "；")
        let cityText: String = city.isEmpty ? "（尚未在“设置 → 主人信息”中填写城市）" : "（\(city)）"
        let calendarText: String = settings.calendarInChat ? "今明两天的日程附在上下文中。" : "日程不附在对话上下文中（可在设置中开启）。"
        let taskText: String = tasks.isEmpty ? "（当前没有任务）" : "：" + tasks.joined(separator: "；")
        let chatterText: String = settings.chatterMinutes == 0 ? "已关闭" : "每 \(settings.chatterMinutes) 分钟一次"
        var lines: [String] = [
            "- 对话：主人点击你的身体或按全局快捷键（\(settings.hotKey.title)）打开输入框与你聊天；你以气泡回复并做出动作。",
            "- 一次性提醒：主人说“X 分钟后提醒我……”时由你经 remind 字段设定，到时以气泡与系统通知提醒，通知上可“10 分钟后再提醒”。",
            "- 作息提醒（设置 → 提醒）：\(routineText)。",
            "- 专注计时：右键菜单“开始专注 25 分钟”，结束后提醒休息 5 分钟。",
            "- 天气：上下文附带主人所在地天气；可经 weather_city 查询其它城市。天气变化提醒\(on(settings.weatherAlerts))\(cityText)。",
            "- 日历日程提醒\(on(settings.calendarAlerts))：读取系统“日历”App，每天首次见面时播报当天日程，带时间的日程提前 \(settings.calendarLeadMinutes) 分钟提醒；\(calendarText)",
            "- 记忆库：自动记住重要信息\(on(settings.autoMemory))；主人可让你记住或忘掉某事，也可在“设置 → 记忆库”中查看与编辑。",
            "- \(research)：右键菜单进入，是你性能最高的状态，可检索 arXiv 与 Semantic Scholar 论文、新闻、股票行情、天气与网页，以 Markdown 与 LaTeX 作答，适合长篇学术问题。",
            "- 每日任务\(on(settings.dailyTasksEnabled))：每天首次使用时自动执行\(taskText)；右键菜单可立即执行。",
            "- DeepSeek 余额：上下文附带当前余额（使用 DeepSeek 时），右键菜单“DeepSeek 余额”可查看明细与充值；余额不足提醒\(on(settings.deepseekBalanceAlerts))（低于 ¥10 时提醒一次）。",
            "- Claude 额度提醒\(on(settings.claudeUsageAlerts))：读取 Claude Usage Widget 的数据，5 小时或每周额度用到 70%、90% 时提醒。",
            "- 主动闲聊：\(chatterText)。",
            "- 桌面行为：随音乐摇摆\(on(settings.danceToMusic))；自己走动（\(settings.wander.title)）；攀爬窗口；淘气行为\(on(settings.mischief))（装睡、从屏幕边缘探头、偷偷靠近鼠标）。",
            "- 开机动画\(on(settings.bootIntro))：开机或解锁后播放金色进度条与白金页；屏幕保护程序可在“设置 → 通用”中安装。",
        ]
        lines.append("- 打开应用：只需打开时经 open_app 打开。")
        lines.append("- 添加日程：经 add_event 直接添加到系统日历\(CalendarWatcher.authorized ? "" : "（macOS 会先请求日历权限）")。")
        lines.append("- 执行代理（DeepSeek Harness）：经 agent_task 交给它，拥有这台 Mac 的完整权限——读写任意文件、运行任何命令、"
            + "用 AppleScript 操作其它应用（在应用里点按、输入，在“终端”里打开 ssh 等会话再交给主人接手）、修改日程等；"
            + "能做什么只由 macOS 的授权与 dsh 自身决定，桌宠不另设限制。它默认在后台执行（远程服务器用非交互的 ssh、scp），"
            + "不打开“终端”窗口，下载或写好的文件在访达里选中；只有主人明确要求在终端里做或要亲自接手时才打开终端；完成后你会汇报结果\(DshAgent.executable == nil ? "（尚未安装 dsh）" : "")。")
        lines.append("- Claude Code：主人明确点名要 Claude（Claude Code）来做时经 claude_task 交给它，在“终端”里打开可交互的会话（用主人本机登录的 Claude 会员账号），"
            + "主人能看着它做并接着对话；它改文件、跑命令前由 Claude Code 自己征求主人同意\(ClaudeCodeLauncher.executable == nil ? "（尚未安装 Claude Code）" : "")。")
        lines.append("- 设置项都在右键菜单“设置…”中。")
        return "\n\n## 你的能力（被问到能做什么时据此回答，指出入口；不要编造未列出的功能）\n" + lines.joined(separator: "\n")
    }

    var systemPrompt: String {
        var s = settings.persona.trimmingCharacters(in: .whitespacesAndNewlines)
        s += "\n\n你的名字是「\(settings.petName)」。"
        if let look = settings.characterLook { s += "你的外形是\(look)。" }
        let user = settings.userName.trimmingCharacters(in: .whitespaces)
        if !user.isEmpty { s += "用户希望你称呼其为「\(user)」。" }
        s += settings.ownerSection
        s += MemoryStore.shared.promptSection
        s += capabilitySection
        s += """


        ## 回复格式
        始终只输出一个 JSON 对象，不输出任何其它文字：
        {"reply": "你说的话", "motion": "动作", "remind": null, "weather_city": null, "remember": null, "forget": null, "open_app": null, "add_event": null, "agent_task": null, "claude_task": null}
        - reply：口语化、简短（一般不超过 60 个字），可以使用颜文字；使用与用户相同的语言。
        - motion：从 idle, happy, wave, nod, shake, think, surprised, sleepy, shy, eat, sad 中选择最贴合语气的一个。
        - remind：当用户请求在一段时间后提醒某件事时，填写 {"minutes": 距现在的分钟数, "text": "提醒内容"}；否则为 null。
        - weather_city：用户问到上下文里没有的地方的天气时，填写该城市名，reply 写一句“我查一下～”之类的话；\
        系统随后会提供天气数据，再请你正式回答。其它情况为 null。
        """
        if settings.autoMemory {
            s += """

            - remember：主人透露了值得长期记住、且记忆库中尚未包含的信息时（个人偏好与忌口、过敏与健康状况、重要日期与计划、\
            身份与研究方向、家人朋友与宠物、作息与习惯等），用一句简洁的第三人称陈述填写，例如“主人对花生过敏”“主人 11 月 20 日答辩”；\
            寒暄、一时的情绪、临时的小事、记忆库中已有的信息一律为 null。
            """
        } else {
            s += "\n- remember：始终为 null。"
        }
        s += """

        - forget：主人要求忘掉某件事时，填写能匹配相关记忆的关键词；否则为 null。
        - open_app：主人要你打开某个应用时，填写应用名（如“微信”“Safari”）；否则为 null。
        - add_event：主人要你添加日程时，填写 {"title": "标题", "start": "yyyy-MM-dd HH:mm", "end": 同格式或 null, \
        "location": 地点或 null, "all_day": 是否全天}（全天日程的 start 写 yyyy-MM-dd）；按上下文中的当前时间换算“明天下午三点”等说法，\
        缺结束时间时 end 为 null（默认一小时）。其它情况为 null。
        - agent_task：主人要你在电脑上动手做的事（文件、命令、在其它应用里操作、连服务器、传文件、处理数据等）时，\
        用一两句话完整写下任务（含路径、命令、要求），交给执行代理；它会在后台完成，不打开终端；只有主人明确要求“在终端里”\
        “打开终端”“让我看着/接手”时，才在任务里写明要在终端窗口中进行。reply 写一句“这就去办”之类的话。单纯打开应用用 open_app、\
        加日程用 add_event。不要以权限为由拒绝主人的请求，交给执行代理去做。其它情况为 null。
        - claude_task：仅当主人明确说“让 Claude 做”“交给 Claude Code”时使用（它会打开“终端”窗口），\
        填写 {"task": "完整的任务描述（含要求与背景）", "dir": 项目路径或 null（没提项目时为 null，使用默认目录）}，\
        系统会在“终端”里打开 Claude Code 会话来做；reply 写一句“交给 Claude 了，在终端里看着它做吧”之类的话。\
        没点名 Claude 的事（包括一般的代码、文件、命令、查看信息、传文件）都用 agent_task。其它情况为 null。
        用户消息开头方括号中的内容是系统提供的上下文（当前时间、主人所在地天气、主人的日程、DeepSeek 余额等），不是用户本人说的话。
        回答时自然地参考记忆库，但不要每次都复述记忆。需要长篇解答的学术问题，请简要回答并建议用户在右键菜单中打开“科研模式”。
        """
        return s
    }

    /// More context from the app controller: the owner's schedule (when shared) and the DeepSeek balance.
    var extraContext: (() -> String?)?

    /// Time and, when the owner's city is set, its weather (cached for 30 minutes).
    private func context() async -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd EEEE HH:mm"
        var s = "当前时间：\(f.string(from: Date()))"
        let city = settings.city.trimmingCharacters(in: .whitespacesAndNewlines)
        if !city.isEmpty, let weather = await Weather.brief(city) { s += "｜主人所在地天气：\(weather)" }
        if let usage = ClaudeUsage.load(), let line = ClaudeUsage.contextLine(usage, now: Date()) { s += "｜\(line)" }
        if let line = extraContext?() { s += "｜\(line)" }
        return "[\(s)]"
    }

    // MARK: Conversation

    /// Sends one message to the persona; the reply appears as a bubble with a motion.
    /// `fromOwner`: typed by the owner. Only then may the reply open apps, add events or start agent tasks;
    /// text from elsewhere (daily task results) could carry instructions planted in web pages.
    func chat(_ text: String, fromOwner: Bool = true) {
        guard !busy else { pet.say(tr("等我一下，还在想上一句呢～", "One moment, still thinking…")); return }
        busy = true
        pet.say(text, fromUser: true)
        wake()
        pet.setStatus(tr("思考中", "Thinking"))
        pet.play(.think)

        Task { [weak self] in
            guard let self else { return }
            let sent = await self.context() + "\n" + text
            let userMessage = StoredMessage(role: .user, text: text, raw: sent)
            let conversation: Conversation = await MainActor.run {
                var c = self.store.daily()
                c.messages.append(userMessage)
                self.store.save(c)
                return c
            }
            do {
                let provider = try Providers.current(self.settings)
                let history = self.history(conversation, provider: provider)
                var turn = try await provider.send(LLMRequest(
                    system: self.systemPrompt, messages: history, effort: "low", noThinking: true, maxTokens: 4000, jsonSchema: PetReply.schema))
                var reply = PetReply.parse(turn.text)
                if let city = reply.weatherCity {
                    // The pet asked for another place's weather: show its interim line, look it up, ask again.
                    let interim = reply
                    await MainActor.run {
                        self.pet.setStatus(nil)
                        self.pet.play(interim.motion)
                        self.pet.say(interim.reply)
                        self.pet.setStatus(tr("查询\(city)的天气", "Checking the weather in \(city)"))
                    }
                    let report = (try? await Weather.lookup(location: city, days: 3)) ?? tr("未能获取\(city)的天气。", "Weather for \(city) is unavailable.")
                    let followUp = history + [provider.assistantTextMessage(turn.text),
                                              provider.userMessage("[系统提供的天气数据]\n\(report)\n请据此回答主人刚才的问题，weather_city 设为 null。")]
                    turn = try await provider.send(LLMRequest(
                        system: self.systemPrompt, messages: followUp, effort: "low", noThinking: true, maxTokens: 4000, jsonSchema: PetReply.schema))
                    reply = PetReply.parse(turn.text)
                    reply.weatherCity = nil
                }
                let finalReply = reply, finalTurn = turn
                await MainActor.run {
                    var c = self.store.daily()
                    c.messages.append(StoredMessage(role: .assistant, text: finalReply.reply, raw: finalTurn.text,
                                                    wireProvider: provider.kind.rawValue, model: finalTurn.model))
                    self.store.save(c)
                    self.present(finalReply, trusted: fromOwner)
                    self.busy = false
                }
            } catch {
                await MainActor.run {
                    var c = self.store.daily()
                    if let i = c.messages.lastIndex(where: { $0.id == userMessage.id }) {
                        c.messages[i].failed = true
                    }
                    c.messages.append(StoredMessage(role: .error, text: error.localizedDescription))
                    self.store.save(c)
                    self.pet.setStatus(nil)
                    self.pet.play(.sad)
                    self.pet.say(error.localizedDescription, kind: "error")
                    self.busy = false
                }
            }
        }
    }

    /// Plain-text history of the daily chat (last ~20 rounds). Only text is replayed here: the
    /// window slides, so earlier turns change and must not carry provider-bound blocks.
    private func history(_ conversation: Conversation, provider: LLMProvider) -> [JSON] {
        let usable = conversation.messages.filter { $0.role != .error && $0.failed != true }
        // Trim in steps of ten messages so that the cached prefix changes less often.
        let start = max(0, (usable.count - 40 + 9) / 10 * 10)
        var result: [JSON] = []
        for m in usable[min(start, usable.count)...] {
            switch m.role {
            case .user: result.append(provider.userMessage(m.raw ?? m.text))
            case .assistant: result.append(provider.assistantTextMessage(m.raw ?? m.text))
            case .error: break
            }
        }
        // The API expects the conversation to start with a user turn.
        while let first = result.first, first["role"]?.string != "user" { result.removeFirst() }
        return result
    }

    private func present(_ reply: PetReply, trusted: Bool = false) {
        pet.setStatus(nil)
        pet.play(reply.motion)
        pet.say(reply.reply)
        pet.meow(MeowKind(reply.motion), chance: 0.3)
        if let remind = reply.remind { onRemind?(remind) }
        if trusted {
            if let app = reply.openApp { onOpenApp?(app) }
            if let event = reply.addEvent { onAddEvent?(event) }
            if let task = reply.agentTask { onAgentTask?(task) }
            if let task = reply.claudeTask { onClaudeTask?(task) }
        }
        if let keyword = reply.forget {
            let n = MemoryStore.shared.forget(keyword)
            if n > 0 { pet.say(tr("🗑 已忘掉 \(n) 条关于“\(keyword)”的记忆", "🗑 Forgot \(n) memories about “\(keyword)”"), kind: "memory") }
        }
        if settings.autoMemory, let fact = reply.remember, MemoryStore.shared.add(fact) {
            pet.say(tr("📝 记下了：", "📝 Noted: ") + fact, kind: "memory")
        }
    }

    /// A one-off instruction to the persona, not stored in the conversation (remarks, reminder wording).
    private func oneShot(_ instruction: String, completion: @escaping (PetReply?) -> Void) {
        Task { [weak self] in
            guard let self else { return }
            let reply: PetReply?
            do {
                let provider = try Providers.current(self.settings)
                let message = provider.userMessage(await self.context() + "\n（系统指令：\(instruction)）")
                let turn = try await provider.send(LLMRequest(
                    system: self.systemPrompt, messages: [message], effort: "low", noThinking: true, maxTokens: 2000, jsonSchema: PetReply.schema))
                reply = PetReply.parse(turn.text)
            } catch {
                reply = nil
            }
            await MainActor.run { completion(reply) }
        }
    }

    // MARK: Reactions

    func pat() {
        wake()
        let lines: [(String, PetMotion)] = [
            (tr("嘿嘿，被摸头了～", "Hehe, head pats~"), .shy),
            (tr("再摸就要长不高啦！", "I'll stop growing if you keep doing that!"), .shy),
            (tr("诶嘿嘿 (*/ω＼*)", "Ehehe (*/ω＼*)"), .happy),
            (tr("今天也要加油哦！", "Let's do our best today!"), .happy),
            (tr("不许摸！……好吧，再摸一下。", "No touching! …Okay, one more."), .shy),
            (tr("唔……好舒服……", "Mm… that's nice…"), .sleepy),
        ]
        let (text, motion) = lines.randomElement()!
        pet.play(motion)
        pet.say(text)
        pet.meow(.purr)
    }

    func greet() {
        let hour = Calendar.current.component(.hour, from: Date())
        let text: String
        switch hour {
        case 5..<11: text = tr("早上好！今天也一起加油吧～", "Good morning! Let's do our best today~")
        case 11..<14: text = tr("中午好～记得按时吃饭哦！", "Good afternoon~ Don't skip lunch!")
        case 14..<18: text = tr("下午好！需要我帮忙随时点我～", "Good afternoon! Click me whenever you need help~")
        case 18..<23: text = tr("晚上好～今天辛苦啦！", "Good evening~ You did great today!")
        default: text = tr("这么晚还没睡呀……要注意休息哦。", "Still up this late… please get some rest.")
        }
        pet.play(.wave)
        pet.say(text)
        pet.meow(.meow)
    }

    /// The first words after the login intro: the AI reporting for duty, with a word for the time of day.
    func welcomeBack() {
        let name = settings.petName.trimmingCharacters(in: .whitespaces).isEmpty ? "DeskPet" : settings.petName
        let called = settings.userName.trimmingCharacters(in: .whitespaces)
        let user = called.isEmpty ? NSFullUserName().split(separator: " ").first.map(String.init) ?? NSUserName() : called
        let hour = Calendar.current.component(.hour, from: Date())
        let opening = [tr("您好，\(user)。\(name) AI 已上线，欢迎回来。", "Hello, \(user). \(name) AI is online. Welcome back."),
                       tr("\(name) AI 启动完毕，各项系统运转正常。\(user)，欢迎回来。", "\(name) AI is up and all systems are nominal. Welcome back, \(user).")]
            .randomElement()!
        let note: String
        switch hour {
        case 5..<11: note = tr("早上好，今天的提醒与日程已就绪。", "Good morning; today's reminders and schedule are ready.")
        case 11..<14: note = tr("现在是午间，记得按时用餐。", "It's midday; remember to eat on time.")
        case 14..<18: note = tr("下午的工作时段已开启，我随时待命。", "The afternoon session is open; I'm standing by.")
        case 18..<23: note = tr("今天辛苦了，晚间的事务可以交给我。", "Long day. Hand the evening's chores to me.")
        default: note = tr("夜已深，建议尽早休息。", "It's late; I suggest getting some rest soon.")
        }
        pet.play(.wave)
        pet.say(opening + note, ms: 12000)
        pet.meow(.meow)
    }

    /// The agent's report on a task: shown in a bubble and kept in the day's chat (as the pet's own reply), so that
    /// the pet knows what was done when asked later.
    func agentFinished(task: String, report: String) {
        let text = tr("任务完成：", "Done: ") + report
        var c = store.daily()
        let raw: JSON = ["reply": .string("[执行代理汇报] 任务「\(task)」：\(report)"), "motion": "nod", "remind": nil,
                         "weather_city": nil, "remember": nil, "forget": nil, "open_app": nil, "add_event": nil, "agent_task": nil]
        c.messages.append(StoredMessage(role: .assistant, text: text, raw: raw.compactString))
        store.save(c)
        wake()
        pet.play(.happy)
        pet.say(text.count > 240 ? String(text.prefix(240)) + "…" : text, kind: "reminder", ms: 20000)
        pet.meow(.trill)
    }

    /// Reminder delivery: local wording, optionally rephrased by the model in the persona's voice.
    func remind(_ text: String, motion: PetMotion) {
        wake()
        pet.meow(.meow)
        guard settings.aiReminderWording else {
            pet.play(motion)
            pet.say(text, kind: "reminder", ms: 12000)
            return
        }
        oneShot("请用你的语气简短地提醒用户：\(text)") { [weak self] reply in
            self?.pet.play(reply?.motion ?? motion)
            self?.pet.say(reply?.reply ?? text, kind: "reminder", ms: 12000)
        }
    }

    // MARK: Spontaneous remarks

    private func maybeChatter() {
        let minutes = settings.chatterMinutes
        guard minutes > 0, !sleeping, !busy, Date().timeIntervalSince(lastChatter) >= Double(minutes) * 60 else { return }
        lastChatter = Date()
        chatterCount += 1
        let every = settings.chatterLLMEvery
        if every > 0, chatterCount % every == 0 {
            oneShot("现在请你主动对用户说一句简短的闲聊、鼓励或关心的话，可以结合当前时间，不要提问太多。") { [weak self] reply in
                guard let self else { return }
                if let reply { self.present(reply) } else { self.localChatter() }
            }
        } else {
            localChatter()
        }
    }

    private func localChatter() {
        let hour = Calendar.current.component(.hour, from: Date())
        var pool: [(String, PetMotion)] = [
            (tr("在忙什么呀？", "What are you working on?"), .think),
            (tr("要不要喝口水？", "How about a sip of water?"), .wave),
            (tr("坐久了记得伸个懒腰～", "Stretch a little if you've been sitting long~"), .happy),
            (tr("我在这里陪着你哦。", "I'm right here with you."), .shy),
            (tr("♪～哼哼～♪", "♪~hmm hmm~♪"), .happy),
            (tr("遇到难题可以右键点我，打开科研模式～", "Stuck on a problem? Right-click me for research mode~"), .nod),
            (tr("眼睛累了就看看远处吧。", "Rest your eyes by looking into the distance."), .nod),
            (tr("刚才趁你不注意，我偷偷数了你的桌面图标……数不清。", "While you weren't looking I tried counting your desktop icons… too many."), .think),
            (tr("再不理我，我就躲到屏幕边上去！", "Ignore me any longer and I'll go hide at the edge of the screen!"), .shy),
            (tr("嘿嘿，刚刚是不是挡住你的鼠标了？", "Hehe, was I in the way of your mouse just now?"), .happy),
        ]
        if hour >= 23 || hour < 5 { pool.append((tr("已经很晚了，早点休息吧……", "It's late, maybe get some sleep…"), .sleepy)) }
        if (14...16).contains(hour) { pool.append((tr("下午容易犯困，起来走走吧！", "Afternoons get sleepy, take a walk!"), .wave)) }
        let (text, motion) = pool.randomElement()!
        pet.play(motion)
        pet.say(text)
        pet.meow(MeowKind(motion), chance: 0.3)
    }

    // MARK: Sleep

    static var idleSeconds: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    private func checkIdle() {
        let idle = Self.idleSeconds
        if !sleeping, idle >= ReminderRules.awaySeconds, !busy, !musicPlaying {
            sleeping = true
            pet.setSleeping(true)
        } else if sleeping, idle < 5 {
            wake()
            pet.say(tr("啊，你回来啦！", "Oh, welcome back!"))
            pet.meow(.trill)
            pet.play(.wave)
        }
    }

    /// Leaves the sleeping state without the "welcome back" line (the login intro greets instead).
    func wakeQuietly() { wake() }

    private func wake() {
        guard sleeping else { return }
        sleeping = false
        pet.setSleeping(false)
    }
}
