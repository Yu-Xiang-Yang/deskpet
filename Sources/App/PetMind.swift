import Foundation
import Combine

/// What the pet's inner life keeps between launches: ~/Library/Application Support/DeskPet/mind.json.
final class MindState: ObservableObject {
    static let shared = MindState()

    /// One moment of thinking (or of consolidating memories), for Settings → Memory.
    struct Entry: Codable, Identifiable, Equatable {
        var id = UUID()
        var date: Date
        /// "idle", "follow_up", "returned" or "digest".
        var trigger: String
        /// The thoughts with their urge, e.g. "4 · 不知道主人的组会怎么样了 → “组会顺利吗？”".
        var thoughts: [String] = []
        /// What the pet said, or nil when it kept quiet.
        var said: String?
        /// Why it kept quiet, or what consolidating did.
        var note: String?
    }

    private struct Snapshot: Codable {
        var digestedUntil: Date?
        var recentRemarks: [String]
        var lastRemark: Date?
        var unanswered: Int
        var faded: Int
        var log: [Entry]
        /// Absent in files of earlier versions.
        var affect: Affect?
    }

    @Published private(set) var log: [Entry] = []
    /// Episodes and impressions forgotten so far.
    @Published private(set) var faded = 0
    /// The daily chat is consolidated up to this message date.
    private(set) var digestedUntil: Date?
    /// The pet's own recent remarks, newest first, for not repeating itself.
    private(set) var recentRemarks: [String] = []
    private(set) var lastRemark: Date?
    /// Remarks in a row the owner did not answer.
    private(set) var unanswered = 0
    /// The pet's mood as last updated (read it through `mood(at:)`, which lets it return toward rest).
    @Published private(set) var affect = Affect(at: Date())
    private let file: URL

    init(file: URL = AppPaths.ensure(AppPaths.dataDir).appendingPathComponent("mind.json")) {
        self.file = file
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: file), let s = try? decoder.decode(Snapshot.self, from: data) {
            digestedUntil = s.digestedUntil
            recentRemarks = s.recentRemarks
            lastRemark = s.lastRemark
            unanswered = s.unanswered
            faded = s.faded
            log = s.log
            if let a = s.affect { affect = a }
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        let s = Snapshot(digestedUntil: digestedUntil, recentRemarks: recentRemarks, lastRemark: lastRemark,
                         unanswered: unanswered, faded: faded, log: log, affect: affect)
        if let data = try? encoder.encode(s) { try? data.write(to: file, options: .atomic) }
    }

    func record(_ entry: Entry) {
        log = Array(([entry] + log).prefix(40))
        save()
    }

    func spoke(_ text: String, at now: Date) {
        lastRemark = now
        recentRemarks = Array(([text] + recentRemarks).prefix(10))
        unanswered += 1
        // The remark before this one was left unanswered: a little deflated.
        if unanswered >= 2 { affect.nudge(dv: -0.08, da: -0.05, because: "主动说的话主人没有回应", at: now) }
        save()
    }

    /// The owner turned to the pet (a message, a pat): glad of it, the more so after remarks left unanswered.
    func ownerSpoke(_ cause: String = "主人来找你说话", dv: Double = 0.04, da: Double = 0.04, at now: Date = Date()) {
        if unanswered >= 2 { affect.nudge(dv: 0.08, da: 0, because: "主人终于回应了", at: now) }
        affect.nudge(dv: dv, da: da, because: cause, at: now)
        unanswered = 0
        save()
    }

    /// The mood at `now`.
    func mood(at now: Date = Date()) -> Affect { affect.at(now) }

    /// Something happened that moves the mood.
    func nudge(dv: Double, da: Double, because cause: String, at now: Date = Date()) {
        affect.nudge(dv: dv, da: da, because: cause, at: now)
        save()
    }

    /// The model named how a moment made the pet feel.
    func feel(_ report: FeelingReport?, at now: Date = Date()) {
        guard let report else { return }
        affect.feel(report, at: now)
        save()
    }

    func digested(until date: Date) {
        digestedUntil = date
        save()
    }

    func addFaded(_ count: Int) {
        faded += count
        save()
    }
}

/// The pet's inner life (after Generative Agents, MemoryBank and Inner Thoughts): it consolidates finished stretches
/// of conversation into memories, lets old memories fade, and between conversations thinks, which now and then turns
/// into a remark or into a question about something the owner mentioned before.
final class PetMind {
    enum Trigger: Equatable {
        /// The chatter interval passed.
        case idle
        /// A follow-up the pet planned is due.
        case followUp
        /// The owner came back after some minutes away.
        case returned(minutes: Int)
        /// The pet has just started (the Mac was started, or the pet opened again).
        case launched
        /// The owner patted its head.
        case patted
        /// Music started (the pet decides whether to sway to it), or stopped after `minutes`.
        case music
        case musicStopped(minutes: Int)
        /// A moment of the owner's day from Settings → Reminders (a meal time, work, a long stretch at the computer,
        /// water), described.
        case routine(String)
        /// Something happened, described: what the pet did or saw, an alert (weather, a balance running low).
        case event(String)

        var name: String {
            switch self {
            case .idle: return "idle"
            case .followUp: return "follow_up"
            case .returned: return "returned"
            case .launched: return "launched"
            case .patted: return "patted"
            case .music: return "music"
            case .musicStopped: return "music_stopped"
            case .routine: return "routine"
            case .event: return "event"
            }
        }

        var prompt: String {
            switch self {
            case .idle: return "一段安静的时间过去了，你在桌面上待着，想到了一些事"
            case .followUp: return "到了要提醒主人的事或要跟进的事的时间"
            case .returned(let minutes): return "主人离开约 \(minutes) 分钟后，刚回到电脑前"
            case .launched: return "你刚刚启动（主人开机或重新打开了你），这是今天（或这次）见到主人的时刻"
            case .patted: return "主人刚刚摸了摸你的头（这是主人在和你互动，通常值得回应）"
            case .music: return "主人开始播放音乐了。除念头外，请用 dance 决定要不要跟着音乐摇摆"
            case .musicStopped(let minutes): return "音乐停了（主人刚才听了约 \(minutes) 分钟）"
            case .routine(let what): return "到了主人作息中的一个时刻：\(what)"
            case .event(let what): return what
            }
        }
    }

    enum Outcome: Equatable {
        case spoke
        /// The pet chose to keep quiet.
        case silent
        /// It could not think: no model service, an error, an unreadable answer.
        case failed
    }

    private let settings = AppSettings.shared
    private let memory = MemoryStore.shared
    private let state = MindState.shared
    private let conversations = ConversationStore.shared
    private unowned let brain: PetBrain

    /// The pet chose (not) to sway to the music that started.
    var onDance: ((Bool) -> Void)?
    /// A reminder was given: also as a system notification, for an owner away from the screen.
    var notify: ((String) -> Void)?

    private(set) var thinking = false
    private(set) var digesting = false
    /// Moments that came while the pet was thinking, thought about next.
    private var queued: [Trigger] = []
    /// Since when the owner has been using the computer without a break of 5 minutes.
    private var activeSince: Date?
    private var nextDigest = Date.distantPast
    /// What the last idle moment that ended in silence saw (idleSignature), and what the one being thought about sees:
    /// an idle moment with nothing new is not thought about again.
    private var quietIdle: String?
    private var idleSeen: String?
    private var nextFollowUp = Date.distantPast
    private var lastFade = Date.distantPast

    init(brain: PetBrain) {
        self.brain = brain
    }

    /// Every minute: forget what faded (hourly), consolidate a finished stretch of conversation, give due reminders,
    /// follow up what is due.
    func tick(now: Date = Date()) {
        activeSince = PetBrain.idleSeconds < 300 ? activeSince ?? now : nil
        // Reminders and events of the calendar are given when due, whatever the hour or the owner is doing.
        if memory.dueFollowUps(at: now).contains(where: { $0.kind == .reminder }) {
            brain.wakeForReminder()
            think(.followUp, now: now)
        }
        if now.timeIntervalSince(lastFade) >= 3600 {
            lastFade = now
            let gone = memory.forgetFaded(at: now)
            if !gone.isEmpty { state.addFaded(gone.count) }
        }
        if settings.autoMemory, !digesting, now >= nextDigest {
            let messages = pending(now: now)
            // A stretch is finished after ten minutes without a message; a long one is taken in parts.
            if let last = messages.last, now.timeIntervalSince(last.date) >= 600 || messages.count >= 24 { digest(messages, now: now) }
        }
        if settings.followUps { followUpIfDue(now) }
    }

    // MARK: Consolidation

    /// Daily-chat messages not consolidated yet (the first time: those of the last two days).
    private func pending(now: Date) -> [StoredMessage] {
        let since = state.digestedUntil ?? now.addingTimeInterval(-2 * 86400)
        return conversations.daily().messages.filter { $0.date > since && $0.role != .error && $0.failed != true }
    }

    /// Consolidates the messages not consolidated yet, now (Settings → Memory).
    func digestNow(done: @escaping (String) -> Void) {
        guard !digesting else { done(tr("正在整理中…", "Already consolidating…")); return }
        digest(pending(now: Date()), now: Date(), done: done)
    }

    /// Lines "10-27 21:13 主人：…" of the messages, each shortened to 240 characters.
    private func transcript<S: Sequence>(_ messages: S) -> String where S.Element == StoredMessage {
        let calendar = memory.calendar
        let pet = settings.petName.trimmingCharacters(in: .whitespaces).isEmpty ? "桌宠" : settings.petName
        return messages.compactMap { m -> String? in
            let who: String
            switch m.role {
            case .user: who = "主人"
            case .assistant: who = pet
            case .error: return nil
            }
            let c = calendar.dateComponents([.month, .day, .hour, .minute], from: m.date)
            let text = m.text.count > 240 ? String(m.text.prefix(240)) + "…" : m.text
            return String(format: "%02d-%02d %02d:%02d ", c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0) + "\(who)：\(text)"
        }.joined(separator: "\n")
    }

    private func digest(_ messages: [StoredMessage], now: Date, done: ((String) -> Void)? = nil) {
        guard let last = messages.last else { done?(tr("没有需要整理的新对话。", "No new conversation to consolidate.")); return }
        // Greetings alone ("你好") hold nothing to remember: skip the model call.
        let said = messages.filter { $0.role == .user }.map(\.text).joined()
        guard MemoryText.normalized(said).count >= 6 else {
            state.digested(until: last.date)
            done?(tr("新对话中没有值得记住的内容。", "Nothing worth remembering in the new conversation."))
            return
        }
        guard Providers.configured(settings) else {
            done?(tr("尚未配置模型服务。", "No model service is configured."))
            return
        }
        digesting = true
        let batch = Array(messages.suffix(60))
        let text = transcript(batch)
        let (known, labels) = memory.digestContext(for: text, at: now)
        let system = settings.addressed(Self.digestPrompt(petName: settings.petName))
        // What the owner was seen doing meanwhile (screen glances), as background for the episodes.
        let since = state.digestedUntil ?? now.addingTimeInterval(-2 * 86400)
        let seen = ScreenWatcher.shared.glances.filter { $0.date > since }.reversed().map { g -> String in
            let c = memory.calendar.dateComponents([.hour, .minute], from: g.date)
            return String(format: "- %02d:%02d ", c.hour ?? 0, c.minute ?? 0) + g.activity
        }
        Task { [weak self] in
            guard let self else { return }
            let context = await self.brain.context()
            var message = "\(context)\n\n## 记忆库中已有的内容\n\(known)\n\n## 需要整理的对话\n\(text)"
            if !seen.isEmpty { message += "\n\n## 这段时间观察到主人在做的事（屏幕观察，供参考）\n" + seen.joined(separator: "\n") }
            message += "\n\n请整理，只输出 JSON。"
            message = self.settings.addressed(message)
            var parsed: MemoryDigest?
            var error: String?
            do {
                // Read off the main thread: the Keychain may ask for access first.
                let provider = try Providers.current(self.settings)
                let turn = try await provider.send(LLMRequest(system: system, messages: [provider.userMessage(message)], effort: "low",
                                                              noThinking: true, maxTokens: 3000, jsonSchema: MemoryDigest.schema))
                parsed = MemoryDigest.parse(turn.text, now: now, calendar: self.memory.calendar)
                if parsed == nil { error = tr("模型的整理结果无法解析。", "The model's digest could not be read.") }
            } catch let e {
                error = e.localizedDescription
            }
            let digest = parsed, failure = error
            await MainActor.run {
                self.digesting = false
                guard let digest else {
                    self.nextDigest = Date().addingTimeInterval(1800)
                    self.state.record(.init(date: Date(), trigger: "digest", note: tr("整理记忆失败：", "Consolidation failed: ") + (failure ?? "")))
                    done?(failure ?? "")
                    return
                }
                let result = self.memory.apply(digest, labels: labels, at: now)
                self.state.digested(until: (batch.last ?? last).date)
                let note = tr("整理了 \(batch.count) 条对话：新增 \(result.added) 条记忆，修改 \(result.changed) 条，删除 \(result.removed) 条",
                              "Consolidated \(batch.count) messages: \(result.added) memories added, \(result.changed) changed, \(result.removed) removed")
                    + (digest.episodes.contains { $0.followUp != nil } ? tr("；记下了要跟进的事", "; noted something to follow up") : "")
                self.state.record(.init(date: Date(), trigger: "digest", note: note))
                done?(note)
            }
        }
    }

    static func digestPrompt(petName: String) -> String {
        """
        你是桌面宠物「\(petName)」的记忆整理模块。【记忆整理】阅读主人与桌宠的一段对话，像人回想一天那样，整理出值得长期记住的内容。\
        对话中“主人”是用户本人，“\(petName)”是桌宠。只输出一个 JSON 对象：
        {"episodes": [{"text": "…", "importance": 5, "emotion": 0, "follow_up_at": null, "follow_up": null}], "facts": [{"text": "…", "importance": 6}], \
        "updates": [{"id": "F1", "text": "…"}], "insight": null}
        各条记忆一律以“主人”作主语；密码、验证码、密钥、卡号等凭据不记原文，至多记其存放位置。
        - episodes：对话中发生或谈到的、与主人本人有关的事（经历、处境、情绪、计划、你们之间值得记住的互动），每条一句第三人称陈述并写明日期，\
        如“10 月 27 日晚主人说组会被导师批评，有些沮丧”。寒暄、问时间、单纯的指令（打开应用、放音乐）与每日任务的检索内容不记；\
        “记忆中已有的近三天经历”里已有的不重复记。importance 为 1–10：日常琐事 1–3，值得一提 4–6，重要的事（考试、答辩、面试、生病、重大情绪）7–10。
        emotion 为这件事对主人的情绪色彩：−1（很负面，如被批评、生病）到 1（很正面，如论文被录用），中性的事为 0；情绪越强烈，记得越久。
        - follow_up_at 与 follow_up：若这件事过后值得关心一下结果（考试、面试、看病、组会、出行、主人说“明天要……”等），\
        follow_up_at 填打算问起的时间（yyyy-MM-dd HH:mm，按上下文中的当前时间推算，通常为事情结束后几小时到一两天，时间在 9:00–22:00 之间），\
        follow_up 填到时想问的事；否则二者为 null。
        - facts：新出现的长期事实（偏好与忌口、过敏与健康、重要日期、身份与研究方向、长期计划、家人朋友与宠物、作息习惯），记忆库已有的不重复记。
        - updates：已有记忆（按编号 F1、E1 等）因这段对话过时、被纠正或相互矛盾时，填 {"id": 编号, "text": 更新后的表述}；需要删除时 text 为 null。\
        例如记忆为“主人每天喝咖啡”而主人说已经戒了，则更新为“主人已戒咖啡”。没有则为空数组。“主人手动记下的”条目不可修改。
        - insight：结合已有记忆与这段对话，若能看出主人一个较稳定的状态或倾向（如“主人这一周常熬夜赶论文”），写一句并给出 importance；没有把握时为 null。
        若附有“屏幕观察”，可据此补充一条概括这段时间主人主要在做什么的经历（如“10 月 28 日上午主人主要在写论文”），不逐条记录。
        没有值得记的内容时，各数组为空、insight 为 null。不要编造对话与观察中没有的信息。
        """
    }

    // MARK: Thinking

    /// The owner's last message in the daily chat.
    private var lastOwnerMessage: Date? {
        conversations.daily().messages.last { $0.role == .user }?.date
    }

    /// A due follow-up is asked about while the owner is at the computer between 8:00 and 23:00, not in the middle
    /// of a conversation (three minutes after the owner's last message) and not within ten minutes of another remark;
    /// at most one attempt in five minutes.
    private func followUpIfDue(_ now: Date) {
        guard !thinking, now >= nextFollowUp, memory.dueFollowUps(at: now).contains(where: { $0.kind != .reminder }) else { return }
        guard (8..<23).contains(memory.calendar.component(.hour, from: now)), brain.mayRemark, PetBrain.idleSeconds < 120 else { return }
        if let last = state.lastRemark, now.timeIntervalSince(last) < 600 { return }
        if let owner = lastOwnerMessage, now.timeIntervalSince(owner) < 180 { return }
        nextFollowUp = now.addingTimeInterval(300)
        think(.followUp, now: now)
    }

    /// "12 分钟", "3 小时", "2 天".
    private static func span(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int(seconds / 60))
        if minutes < 60 { return "\(minutes) 分钟" }
        if minutes < 24 * 60 { return "\(minutes / 60) 小时" }
        return "\(minutes / (24 * 60)) 天"
    }

    /// What the pet knows of the owner's state: activity, the last conversation, its own last remark.
    private func situation(_ now: Date) -> String {
        var parts: [String] = []
        let idle = PetBrain.idleSeconds
        parts.append(idle < 60 ? "主人正在使用电脑（\(Int(idle)) 秒前有键盘或鼠标操作）" : "主人约 \(Self.span(idle)) 没有操作电脑")
        if let owner = lastOwnerMessage, memory.calendar.isDate(owner, inSameDayAs: now) {
            parts.append("主人上次和你说话是 \(Self.span(now.timeIntervalSince(owner)))前")
        } else {
            parts.append("主人今天还没有和你说过话")
        }
        if let last = state.lastRemark {
            var s = "你上次主动开口是 \(Self.span(now.timeIntervalSince(last)))前"
            if state.unanswered > 0 { s += "，主人没有回应（已连续 \(state.unanswered) 次）" }
            parts.append(s)
        }
        if let since = activeSince, now.timeIntervalSince(since) >= 600 {
            parts.append("主人已连续使用电脑约 \(Self.span(now.timeIntervalSince(since)))（中间没有离开 5 分钟以上）")
        }
        if brain.musicPlaying { parts.append("主人正在听音乐") }
        var text = "主人状态：" + parts.joined(separator: "；") + "。"
        let routine = Self.routine(settings.reminders)
        if !routine.isEmpty { text += "\n主人的作息参考（由主人在设置中填写，供你判断何时关心，不必照本宣科）：" + routine + "。" }
        return text
    }

    /// The owner's day as set in Settings → Reminders, in words; empty when nothing is set.
    static func routine(_ r: ReminderConfig) -> String {
        var parts: [String] = []
        if r.mealsEnabled, !r.mealTimes.isEmpty { parts.append("用餐时间 " + r.mealTimes.joined(separator: "、")) }
        if r.workEnabled { parts.append("工作时间 \(r.workStart)–\(r.workEnd)" + (r.weekdaysOnly ? "（仅工作日）" : "")) }
        if r.sedentaryEnabled { parts.append("希望连续坐约 \(r.sedentaryMinutes) 分钟后起来活动") }
        if r.waterEnabled { parts.append("希望大约每 \(r.waterMinutes) 分钟喝一次水") }
        return parts.joined(separator: "；")
    }

    static var thoughtPrompt: String {
        """


        ## 现在的任务：内心念头【念头】
        此刻主人没有在跟你说话，你在自己想事情。请以上面人设中的身份，产生 1–3 个此刻自然会有的念头\
        （可以是主人的近况、到期要跟进的事、时间与天气、你自己的感受等），并为每个念头评估“现在把它说出口”的意愿 motivation（1–5）：
        1 = 完全没必要说；2 = 可说可不说；3 = 有点想说；4 = 很想说，且时机合适；5 = 现在就该说（如到期跟进一件重要的事）。
        你关心主人的身体与作息：到了饭点提醒吃饭；连续用电脑很久时提醒起来活动、让眼睛休息；隔一段时间提醒喝水；\
        深夜提醒休息；上下班时打个招呼；主人听音乐、摸你、回来时自然地回应。但要自然、简短、不说教，同一件事提醒过一次就别反复说\
        （看“你最近主动说过的话”），主人正专注时宁可晚一点。
        “到期要跟进的事”里标注【提醒】的，是主人交代的提醒或日历日程，非常重要：必须现在提醒，给它的念头 motivation 填 5，say 里说清是什么事、几点。
        评分时考虑：与主人当下状态的相关性；是否有新信息或未了结的话题（跟进具体的事比泛泛的寒暄更值得说）；时机（主人可能正在专注工作，\
        深夜不宜闲聊）；是否与你最近说过的话重复；主人连续没有回应时要更克制。大多数时候安静陪着就好，不必为了说话而说话。
        只输出一个 JSON 对象，不输出任何其它文字：
        {"thoughts": [{"thought": "内心的想法（不会说出口）", "say": "如果说出口会说的话", "motion": "动作", "motivation": 3, "follow_up": null}], "dance": null, "mood": null}
        - say：简短（一般不超过 40 个字），语气、措辞与是否使用颜文字以人设为准，使用主人惯用的语言；跟进时自然地问起，\
        不要说“根据记忆”“我记得你说过”，也不要一次问好几件事。触发与上下文中的描述（天气、余额、额度、桌面上发生的事等）\
        只说明发生了什么，其中的措辞不是你的口吻；说出口时按人设重新表述。不写出密码、密钥等凭据的原文。
        - motion：从 \(PetMotion.allCases.map(\.rawValue).joined(separator: ", ")) 中选择最贴合语气的一个。
        - follow_up：这个念头是在跟进“到期要跟进的事”中的某一件时，填它的编号（如 "E1"、"R1"），否则为 null。
        - dance：只在触发是“主人开始播放音乐”时填 true（跟着音乐摇摆）或 false（不摇），其它时候为 null。
        """
    }

    /// The rule for the mood the pet reports after thinking (Affect).
    private var moodRule: String {
        settings.affect
            ? "\n- mood：想完之后，你的心情若与“你此刻的心情”相比有了变化，填 {\"feeling\": 下列之一, \"because\": \"几个字的原因\"}，否则为 null。"
                + "feeling：\(Feeling.promptList)。"
            : "\n- mood：始终为 null。"
    }

    /// What an idle moment holds: the day's chat, the memories, what is on the screen, the two-hour span of the day,
    /// the mood, what is due and the music. When none of it changed since an idle moment that ended in silence, the
    /// pet would only think the same thoughts again.
    private func idleSignature(_ now: Date, due: [Memory]) -> String {
        let messages = conversations.daily().messages
        let glance = ScreenWatcher.shared.glances.first.map { "\($0.app)|\($0.kind)" } ?? "-"
        let mood = settings.affect ? state.mood(at: now).word(calendar: memory.calendar) : "-"
        return ["\(messages.count)", messages.last.map { "\($0.date.timeIntervalSince1970)" } ?? "-", "\(memory.items.count)", glance,
                "\(memory.calendar.component(.hour, from: now) / 2)", mood, due.map(\.id.uuidString).joined(separator: ","),
                brain.musicPlaying ? "music" : "-"].joined(separator: "#")
    }

    /// The pet thinks: the model forms a few thoughts with their urge, and the strongest is voiced when it reaches the
    /// threshold (Talkativeness, raised by unanswered remarks) and repeats nothing said lately. Due follow-ups are part
    /// of what it thinks about; those it lets pass are retried 45 minutes later.
    func think(_ trigger: Trigger, now: Date = Date(), completion: ((Outcome) -> Void)? = nil) {
        guard !thinking else {
            if !queued.contains(trigger), queued.count < 3 { queued.append(trigger) }
            return
        }
        let calendar = memory.calendar
        // Due reminders always, then the episodes to follow up (when that is on); at most three in all.
        let dueAll = memory.dueFollowUps(at: now)
        let due = Array((dueAll.filter { $0.kind == .reminder } + (settings.followUps ? dueAll.filter { $0.kind != .reminder } : [])).prefix(3))
        func label(_ m: Memory, _ i: Int) -> String { (m.kind == .reminder ? "R" : "E") + "\(i + 1)" }
        let labels = Dictionary(uniqueKeysWithValues: due.enumerated().map { (label($0.element, $0.offset), $0.element.id) })
        let dueLines = due.enumerated().map { MemoryRecall.line($0.element, now: now, calendar: calendar, label: label($0.element, $0.offset)) }
        idleSeen = trigger == .idle ? idleSignature(now, due: due) : nil
        if let seen = idleSeen, seen == quietIdle {
            completion?(.silent)
            return
        }
        guard Providers.configured(settings) else {
            conclude(trigger, thoughts: nil, dance: nil, failure: tr("没有配置模型服务。", "No model service."), threshold: 5, remarks: [],
                     labels: labels, due: due, now: now, completion: completion)
            return
        }
        thinking = true
        let recent = conversations.daily().messages.filter { $0.role != .error }.suffix(8)
        let query = (recent.map(\.text) + due.map(\.text)).joined(separator: "\n")
        let block = memory.recallBlock(for: query, at: now).text
        let system = settings.addressed(brain.personaSection + memory.coreSection(at: now) + Self.thoughtPrompt + moodRule)
        let threshold = InnerThoughts.threshold(base: settings.talkativeness.threshold, unanswered: state.unanswered,
                                                moodShift: settings.affect ? state.mood(at: now).urgeShift(calendar: calendar) : 0)
        let remarks = state.recentRemarks
        var message = "（系统：现在不是主人在对你说话，而是你自己在想事情。触发：\(trigger.prompt)。）\n" + situation(now)
        if !block.isEmpty { message += "\n\n## 可能相关的记忆\n" + block }
        if !recent.isEmpty { message += "\n\n## 最近的对话\n" + transcript(recent) }
        if !dueLines.isEmpty { message += "\n\n## 到期要跟进的事（按编号）\n" + dueLines.joined(separator: "\n") }
        if !remarks.isEmpty { message += "\n\n## 你最近主动说过的话（不要重复）\n" + remarks.prefix(5).map { "- " + $0 }.joined(separator: "\n") }
        message += brain.moodSection(at: now)
        message += "\n\n请产生此刻的念头并评估说出口的意愿，只输出 JSON。"
        let request = settings.addressed(message)
        Task { [weak self] in
            guard let self else { return }
            let context = await self.brain.context()
            var parsed: [InnerThought]?
            var dance: Bool?
            var feeling: FeelingReport?
            var error: String?
            do {
                let provider = try Providers.current(self.settings)
                let turn = try await provider.send(LLMRequest(system: system, messages: [provider.userMessage(context + "\n" + request)],
                                                              effort: "low", noThinking: true, maxTokens: 1500, jsonSchema: InnerThoughts.schema))
                parsed = InnerThoughts.parse(turn.text)
                dance = InnerThoughts.dance(turn.text)
                feeling = InnerThoughts.mood(turn.text)
                if parsed == nil { error = tr("念头无法解析。", "The thoughts could not be read.") }
            } catch let e {
                error = e.localizedDescription
            }
            let thoughts = parsed, failure = error, sway = dance, felt = feeling
            await MainActor.run {
                if self.settings.affect { self.state.feel(felt) }
                self.conclude(trigger, thoughts: thoughts, dance: sway, failure: failure, threshold: threshold, remarks: remarks,
                              labels: labels, due: due, now: now, completion: completion)
            }
        }
    }

    private func conclude(_ trigger: Trigger, thoughts: [InnerThought]?, dance: Bool?, failure: String?, threshold: Double,
                          remarks: [String], labels: [String: UUID], due: [Memory], now: Date, completion: ((Outcome) -> Void)?) {
        thinking = false
        defer {
            if !queued.isEmpty { think(queued.removeFirst()) }
        }
        if trigger == .music { onDance?(dance ?? false) }
        guard let thoughts else {
            state.record(.init(date: now, trigger: trigger.name, note: failure))
            giveReminders(due, except: nil)
            completion?(.failed)
            return
        }
        let lines = thoughts.map { t in
            String(format: "%.0f · ", t.motivation) + t.thought + (t.say.isEmpty ? "" : " → “\(t.say)”")
        }
        var followed: UUID?
        let outcome: Outcome
        let reminderIDs = Set(due.filter { $0.kind == .reminder }.map(\.id))
        let chosen = InnerThoughts.choose(thoughts, threshold: threshold, recent: remarks)
        // A thought that gives a reminder is said whatever the pet is doing.
        let givesReminder: Bool = { if case .success(let t) = chosen, let l = t.followUp, let id = labels[l] { return reminderIDs.contains(id) }; return false }()
        switch chosen {
        case .success(let t) where brain.mayRemark || givesReminder:
            brain.remark(t.say, motion: t.motion, reminder: givesReminder)
            state.spoke(t.say, at: Date())
            if let label = t.followUp, let id = labels[label] {
                memory.followedUp(id, at: Date())
                followed = id
                if reminderIDs.contains(id) { notify?(t.say) }
            }
            state.record(.init(date: now, trigger: trigger.name, thoughts: lines, said: t.say))
            outcome = .spoke
        case .success:
            state.record(.init(date: now, trigger: trigger.name, thoughts: lines, note: tr("想说时主人已在忙别的，没说出口", "The moment passed")))
            outcome = .silent
        case .failure(let silence):
            let note: String
            switch silence.reason {
            case .weak: note = tr("念头不够强烈（开口阈值 \(String(format: "%.1f", threshold))），没说出口", "Not strong enough to say (threshold \(String(format: "%.1f", threshold)))")
            case .repeated: note = tr("与最近说过的话重复，没说出口", "Would repeat a recent remark")
            case .empty: note = tr("没有想说的话", "Nothing to say")
            }
            state.record(.init(date: now, trigger: trigger.name, thoughts: lines, note: note))
            outcome = .silent
        }
        if trigger == .idle { quietIdle = outcome == .silent ? idleSeen : nil }
        // Owner patted the pet and it kept quiet: it still reacts with the motion it thought of.
        if trigger == .patted, outcome != .spoke, let top = thoughts.max(by: { $0.motivation < $1.motivation }) { brain.react(top.motion) }
        // Reminders are never left out; due follow-ups the pet did not ask about wait for a better moment.
        giveReminders(due, except: followed)
        for m in due where m.kind != .reminder && m.id != followed { memory.postponeFollowUp(m.id, retry: Date().addingTimeInterval(45 * 60)) }
        completion?(outcome)
    }

    /// The due reminders that no thought gave (the pet kept quiet, or could not think): said as they are, with a
    /// notification.
    private func giveReminders(_ due: [Memory], except given: UUID?) {
        for m in due where m.kind == .reminder && m.id != given {
            let said = settings.addressed(m.text)
            let text = said.hasPrefix("日程") || said.hasPrefix("提醒") ? said : tr("提醒：", "Reminder: ") + said
            brain.remark(text, motion: .surprised, reminder: true)
            notify?(text)
            memory.followedUp(m.id, at: Date())
        }
    }

    /// Plain text of the state for test runs (DESKPET_DIR/mind.txt).
    var report: String {
        var lines = ["unanswered=\(state.unanswered) faded=\(state.faded) digestedUntil=\(state.digestedUntil.map { "\($0)" } ?? "nil")"]
        for m in memory.items {
            lines.append("memory\t\(m.kind.rawValue)\t\(m.importance)\t\(m.followUp.map { "\($0)" } ?? "-")\t\(m.text)")
        }
        for g in ScreenWatcher.shared.glances.prefix(5) {
            lines.append("glance\t\(g.app)\t\(g.kind)\t\(g.unseen)\t\(g.activity)")
        }
        for e in state.log.prefix(10) {
            lines.append("log\t\(e.trigger)\t\(e.said ?? "-")\t\(e.note ?? "-")\t\(e.thoughts.joined(separator: " | "))")
        }
        return lines.joined(separator: "\n")
    }
}
