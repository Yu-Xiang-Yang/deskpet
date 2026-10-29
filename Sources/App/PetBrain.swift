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
    var onLidAwake: ((Bool) -> Void)?

    private var busy = false
    private var chatterTimer: Timer?
    private var idleTimer: Timer?
    private var lastChatter = Date()
    private(set) var sleeping = false
    private var sleptAt: Date?
    /// Consolidating memories and thinking between conversations.
    private(set) lazy var mind = PetMind(brain: self)
    /// Whether the app lets the pet speak of its own accord now (no research mode, chat box or intro in the way).
    var mayInterrupt: (() -> Bool)?
    /// The pet may speak of its own accord: awake, not answering, and nothing else in the way.
    var mayRemark: Bool { !sleeping && !busy && (mayInterrupt?() ?? true) }
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
        let chatter = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            self?.maybeChatter()
            self?.mind.tick()
        }
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
        let chatterText: String = settings.chatterMinutes == 0 ? "已关闭"
            : settings.innerThoughts ? "每 \(settings.chatterMinutes) 分钟想一想，念头足够强烈、时机合适时才开口（健谈程度：\(settings.talkativeness.title)）"
            : "每 \(settings.chatterMinutes) 分钟一次"
        var lines: [String] = [
            "- 对话：主人点击你的身体或按全局快捷键（\(settings.hotKey.title)）打开输入框与你聊天；你以气泡回复并做出动作。",
            "- 提醒：主人说“X 分钟后提醒我……”时由你经 remind 字段设定；它作为重要程度最高的记忆保存，到点时你会想起并提醒，"
                + "同时发系统通知（通知上可“10 分钟后再提醒”）。",
            "- 关心作息：不再有固定的定时提醒；主人在“设置 → 提醒”中填写的作息（\(routineText)）到点时会让你想一想，由你判断要不要、怎样关心。",
            "- 专注计时：右键菜单“开始专注 25 分钟”，结束后提醒休息 5 分钟。",
            "- 天气：上下文附带主人所在地天气；可经 weather_city 查询其它城市。天气变化提醒\(on(settings.weatherAlerts))\(cityText)。",
            "- 日历日程\(on(settings.calendarAlerts))：读取系统“日历”App，今明两天的日程作为提醒记入记忆库，带时间的日程提前 \(settings.calendarLeadMinutes) 分钟由你提醒；\(calendarText)",
            "- 记忆库：自动记住重要信息\(on(settings.autoMemory))；分为长期事实、经历（每段对话结束后整理）与印象，经历与印象若不再被提起会逐渐淡忘，"
                + "被再次提起时记得更久；主人可让你记住或忘掉某事，也可在“设置 → 记忆库”中查看与编辑。",
            "- \(research)：右键菜单进入，是你性能最高的状态，可检索 arXiv 与 Semantic Scholar 论文、新闻、股票行情、天气与网页，以 Markdown 与 LaTeX 作答，适合长篇学术问题。",
            "- 每日任务\(on(settings.dailyTasksEnabled))：每天首次使用时自动执行\(taskText)；右键菜单可立即执行。",
            "- DeepSeek 余额：上下文附带当前余额（使用 DeepSeek 时），右键菜单“DeepSeek 余额”可查看明细与充值；余额不足提醒\(on(settings.deepseekBalanceAlerts))（低于 ¥10 时提醒一次）。",
            "- Claude API 花费：主人在“设置 → 模型”中填写 Admin API key 后，上下文附带今日与本月的花费，以及据主人填入的余额推算的剩余；右键菜单“Claude API 花费”可查看并打开 Console 结算页（剩余余额无法直接查询，只能推算）。",
            "- Claude 额度提醒\(on(settings.claudeUsageAlerts))：读取 Claude Usage Widget 的数据，5 小时或每周额度用到 70%、90% 时提醒。",
            "- 观察屏幕\(on(settings.screenAwareness))：每 \(settings.screenMinutes) 分钟截屏一次，由模型概括主人此刻在做什么（截图不保存，只保留一句描述；"
                + "主人指定的应用不截屏）；上下文中的“主人屏幕上”即来自于此。主人可在“设置 → 提醒 → 观察屏幕”中开关并授予录屏权限。",
            "- 主动闲聊：\(chatterText)。跟进之前聊过的事\(on(settings.followUps))：主人提到考试、组会、看病等事情时，你会在事后找合适的时机问问结果。",
            "- 桌面行为：随音乐摇摆\(on(settings.danceToMusic))；自己走动（\(settings.wander.title)）；攀爬窗口；淘气行为\(on(settings.mischief))（装睡、从屏幕边缘探头、偷偷靠近鼠标）。",
            "- 朗读气泡\(on(settings.speech))：开启后你说的每个气泡都会被读出来（\(settings.speechEngine == .cloud ? "云端语音" : "系统语音")；科研回答只读开头约 \(Speaker.answerLimit) 字），主人发消息时停下；执行代理与 Claude Code 的交办、汇报与报错以及超过 \(settings.speechMaxChars > 0 ? "\(settings.speechMaxChars) 字" : "设定字数") 的长文只显示不朗读；在“设置 → 通用 → 语音”中开关、选择声音与语速。使用硅基流动云端语音时，右键菜单“语音余额”与该设置页显示账户余额；硅基流动已停用余额查询接口时，二者说明原因并提供控制台入口。",
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
        lines.append("- 合盖不休眠：经 lid_awake 让 Mac 合上盖子后继续运行、联网跑代码（true）或恢复合盖休眠（false），"
            + "macOS 会弹出管理员授权框由主人确认；右键菜单“合盖不休眠”也可切换。当前：\(LidSleep.staysAwake ? "合盖不休眠" : "合盖会休眠")。")
        lines.append("- 设置项都在右键菜单“设置…”中。")
        return "\n\n## 你的能力（被问到能做什么时据此回答，指出入口；不要编造未列出的功能）\n" + lines.joined(separator: "\n")
    }

    /// Persona, name, look (and, with the default persona, the character's speech habit), how to call the owner, and
    /// the owner's background.
    var personaSection: String {
        let map = settings.selectedModel?.map
        return Persona.section(persona: settings.persona, isDefault: settings.isDefaultPersona, name: settings.petName,
                               look: map?["look"]?.string, habit: map?["habit"]?.string, ownerName: settings.userName)
            + settings.ownerSection
    }

    var systemPrompt: String {
        var s = personaSection
        s += MemoryStore.shared.coreSection(at: Date())
        s += capabilitySection
        s += """


        ## 回复格式
        始终只输出一个 JSON 对象，不输出任何其它文字：
        {"reply": "你说的话", "motion": "动作", "remind": null, "weather_city": null, "remember": null, "forget": null, "open_app": null, "add_event": null, "agent_task": null, "claude_task": null}
        - reply：简短（一般不超过 60 个字），语气、措辞与是否使用颜文字以上面的人设为准；使用与用户相同的语言。\
        不在 reply 中写出密码、验证码、密钥等凭据的原文（它会显示在气泡里并被朗读）；需要用到时交给执行代理，或说明存放位置。
        - motion：从 idle, happy, wave, nod, shake, think, surprised, sleepy, shy, eat, sad, swipe（伸爪拍一下，调皮）, grab（站起来举起双爪去抓东西，好奇、想玩）, \
        sniff（凑近嗅嗅，好奇）, perk（竖起耳朵，警觉或感兴趣）, stretch（伸懒腰打哈欠，困倦或放松）, groom（舔爪洗脸，悠闲得意）, \
        swish（甩尾巴，有点不满）中选择最贴合语气的一个。
        - remind：当用户请求在一段时间后提醒某件事时，填写 {"minutes": 距现在的分钟数, "text": "提醒内容"}；否则为 null。
        - weather_city：用户问到上下文里没有的地方的天气时，填写该城市名，reply 简短说明正在查询；\
        系统随后会提供天气数据，再请你正式回答。其它情况为 null。
        """
        if settings.autoMemory {
            s += """

            - remember：主人透露了值得长期记住、且记忆库中尚未包含的信息时（个人偏好与忌口、过敏与健康状况、重要日期与计划、\
            身份与研究方向、家人朋友与宠物、作息与习惯等），用一句简洁的第三人称陈述填写，以“主人”作主语，\
            例如“主人对花生过敏”“主人 11 月 20 日答辩”；寒暄、一时的情绪、临时的小事、记忆库中已有的信息一律为 null；\
            密码、验证码、密钥、卡号等凭据不记原文，至多记其存放位置。
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
        - lid_awake：主人要求合上盖子也不休眠、合盖继续跑代码时填 true；要求恢复合盖休眠时填 false；其它情况为 null。\
        系统会弹出 macOS 管理员授权框，reply 写一句“确认一下授权就好”之类的话。
        用户消息开头方括号中的内容是系统提供的上下文（当前时间、主人所在地天气、主人的日程、DeepSeek 余额等），不是用户本人说的话；\
        其后“相关记忆”一节是系统从记忆库中检索出的、与此刻话题可能相关的记忆，同样不是主人说的话。
        回答时自然地参考记忆库，但不要每次都复述记忆；经历记忆标有日期，越久远越模糊，提起时注意时间。需要长篇解答的学术问题，请简要回答并建议用户在右键菜单中打开“科研模式”。
        """
        return settings.addressed(s)
    }

    /// More context from the app controller: the owner's schedule (when shared) and the DeepSeek balance.
    var extraContext: (() -> String?)?

    /// Time and, when the owner's city is set, its weather (cached for 30 minutes).
    func context() async -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd EEEE HH:mm"
        var s = "当前时间：\(f.string(from: Date()))"
        let city = settings.city.trimmingCharacters(in: .whitespacesAndNewlines)
        if !city.isEmpty, let weather = await Weather.brief(city) { s += "｜主人所在地天气：\(weather)" }
        if let usage = ClaudeUsage.load(), let line = ClaudeUsage.contextLine(usage, now: Date()) { s += "｜\(line)" }
        if let line = extraContext?() { s += "｜\(line)" }
        return settings.addressed("[\(s)]")
    }

    // MARK: Conversation

    /// Sends one message to the persona; the reply appears as a bubble with a motion.
    /// `fromOwner`: typed by the owner. Only then may the reply open apps, add events or start agent tasks;
    /// text from elsewhere (daily task results) could carry instructions planted in web pages.
    func chat(_ text: String, fromOwner: Bool = true) {
        guard !busy else { pet.say(tr("上一句还在处理，请稍等。", "Still on the last message, one moment.")); return }
        busy = true
        pet.say(text, fromUser: true)
        wake()
        pet.setStatus(tr("思考中", "Thinking"))
        pet.play(.think)
        MindState.shared.ownerSpoke()
        // Memories that matter for this message (and the pet's last words, which it may answer): attached to the
        // request only, not stored, so that the history stays as it was sent before.
        let now = Date()
        let lastWords = store.daily().messages.last { $0.role == .assistant }.map { $0.text + "\n" } ?? ""
        let recalled = MemoryStore.shared.recallBlock(for: lastWords + text, at: now)
        MemoryStore.shared.recall(recalled.relevant, at: now)

        Task { [weak self] in
            guard let self else { return }
            let context = await self.context()
            let sent = context + "\n" + text
            let withMemories = recalled.text.isEmpty ? sent
                : context + self.settings.addressed("\n\n## 相关记忆（系统检索，并非主人所说）\n" + recalled.text) + "\n\n" + text
            let userMessage = StoredMessage(role: .user, text: text, raw: sent)
            let conversation: Conversation = await MainActor.run {
                var c = self.store.daily()
                c.messages.append(userMessage)
                self.store.save(c)
                return c
            }
            do {
                let provider = try Providers.current(self.settings)
                let history = self.history(conversation, provider: provider, overrides: [userMessage.id: withMemories])
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
    /// `overrides` replace the stored text of some messages in this request (the new message with its memories).
    private func history(_ conversation: Conversation, provider: LLMProvider, overrides: [UUID: String] = [:]) -> [JSON] {
        let usable = conversation.messages.filter { $0.role != .error && $0.failed != true }
        // Trim in steps of ten messages so that the cached prefix changes less often.
        let start = max(0, (usable.count - 40 + 9) / 10 * 10)
        // Consecutive messages of one role (a remark of the pet's own after its reply, an agent's report) are joined:
        // some services want the roles to alternate.
        var turns: [(role: StoredMessage.Role, text: String)] = []
        for m in usable[min(start, usable.count)...] where m.role != .error {
            let text = overrides[m.id] ?? m.raw ?? m.text
            if let last = turns.last, last.role == m.role { turns[turns.count - 1].text += "\n" + text } else { turns.append((m.role, text)) }
        }
        var result: [JSON] = turns.map { $0.role == .user ? provider.userMessage($0.text) : provider.assistantTextMessage($0.text) }
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
            if let awake = reply.lidAwake { onLidAwake?(awake) }
        }
        if let keyword = reply.forget {
            let n = MemoryStore.shared.forget(keyword)
            if n > 0 { pet.say(tr("🗑 已忘掉 \(n) 条关于“\(keyword)”的记忆", "🗑 Forgot \(n) memories about “\(keyword)”"), kind: "memory") }
        }
        if settings.autoMemory, let fact = reply.remember, MemoryStore.shared.add(fact) {
            pet.say(tr("📝 记下了：", "📝 Noted: ") + settings.addressed(fact), kind: "memory")
        }
    }

    /// Lets the pet think about a moment (PetMind) when its inner life is on; otherwise it keeps quiet.
    func consider(_ trigger: PetMind.Trigger) {
        guard settings.innerThoughts else { return }
        mind.think(trigger)
    }

    /// The motion the pet thought of, without words (it chose to keep quiet when patted).
    func react(_ motion: PetMotion) {
        pet.play(motion)
    }

    /// A reminder is due: the pet wakes up for it.
    func wakeForReminder() { wake() }

    /// A remark of the pet's own accord (an inner thought said aloud): shown, and kept in the day's chat so that the
    /// owner can answer it. A reminder stays longer, in the reminder style.
    func remark(_ text: String, motion: PetMotion, reminder: Bool = false) {
        let raw: JSON = ["reply": .string(text), "motion": .string(motion.rawValue), "remind": nil, "weather_city": nil, "remember": nil,
                         "forget": nil, "open_app": nil, "add_event": nil, "agent_task": nil]
        var c = store.daily()
        c.messages.append(StoredMessage(role: .assistant, text: text, raw: raw.compactString))
        store.save(c)
        pet.play(motion)
        if reminder { pet.say(text, kind: "reminder", ms: 15000) } else { pet.say(text) }
        pet.meow(MeowKind(motion), chance: reminder ? 1 : 0.3)
    }

    // MARK: Reactions

    /// The owner patted the pet: a purr at once, then it thinks of how to respond (words and motion).
    func pat() {
        wake()
        pet.meow(.purr)
        MindState.shared.ownerSpoke()
        consider(.patted)
    }

    /// The first moment of a launch (also right after the login intro): the pet thinks of what to say, if anything.
    func greet() {
        consider(.launched)
    }

    func welcomeBack() {
        consider(.launched)
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
        pet.say(text.count > 240 ? String(text.prefix(240)) + "…" : text, kind: "reminder", ms: 20000, aloud: false)
        pet.meow(.trill)
    }

    /// A notice of a tool the owner started (the focus timer): said as it is.
    func notice(_ text: String, motion: PetMotion) {
        wake()
        pet.play(motion)
        pet.say(text, kind: "reminder", ms: 12000)
    }

    // MARK: Spontaneous remarks

    /// Every chatter interval the pet thinks (PetMind) and speaks only when a thought is strong enough.
    private func maybeChatter() {
        let minutes = settings.chatterMinutes
        guard minutes > 0, mayRemark, !mind.thinking, Date().timeIntervalSince(lastChatter) >= Double(minutes) * 60 else { return }
        lastChatter = Date()
        consider(.idle)
    }

    // MARK: Sleep

    static var idleSeconds: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    private func checkIdle() {
        let idle = Self.idleSeconds
        if !sleeping, idle >= ReminderRules.awaySeconds, !busy, !musicPlaying {
            sleeping = true
            sleptAt = Date().addingTimeInterval(-idle)
            pet.setSleeping(true)
        } else if sleeping, idle < 5 {
            let away = sleptAt.map { Date().timeIntervalSince($0) } ?? 0
            wake()
            // Back after an absence: the pet thinks of what to say (it may ask how something went, or say nothing).
            consider(.returned(minutes: max(1, Int(away / 60))))
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
