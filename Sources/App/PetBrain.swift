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

    var systemPrompt: String {
        var s = settings.persona.trimmingCharacters(in: .whitespacesAndNewlines)
        s += "\n\n你的名字是「\(settings.petName)」。"
        if let look = settings.characterLook { s += "你的外形是\(look)。" }
        s += settings.ownerSection
        let user = settings.userName.trimmingCharacters(in: .whitespaces)
        if !user.isEmpty { s += "用户希望你称呼其为「\(user)」。" }
        s += """


        ## 回复格式
        始终只输出一个 JSON 对象，不输出任何其它文字：
        {"reply": "你说的话", "motion": "动作", "remind": null}
        - reply：口语化、简短（一般不超过 60 个字），可以使用颜文字；使用与用户相同的语言。
        - motion：从 idle, happy, wave, nod, shake, think, surprised, sleepy, shy, eat, sad 中选择最贴合语气的一个。
        - remind：当用户请求在一段时间后提醒某件事时，填写 {"minutes": 距现在的分钟数, "text": "提醒内容"}；否则为 null。
        用户消息开头方括号中的内容是系统提供的上下文（当前时间、主人所在地天气等），不是用户本人说的话。
        - weather_city：用户问到上下文里没有的地方的天气时，填写该城市名，reply 写一句“我查一下～”之类的话；\
        系统随后会提供天气数据，再请你正式回答。其它情况为 null。
        需要长篇解答的学术问题，请简要回答并建议用户在右键菜单中打开“科研模式”。
        """
        return s
    }

    /// Time and, when the owner's city is set, its weather (cached for 30 minutes).
    private func context() async -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd EEEE HH:mm"
        var s = "当前时间：\(f.string(from: Date()))"
        let city = settings.city.trimmingCharacters(in: .whitespacesAndNewlines)
        if !city.isEmpty, let weather = await Weather.brief(city) { s += "｜主人所在地天气：\(weather)" }
        return "[\(s)]"
    }

    // MARK: Conversation

    /// Sends one message to the persona; the reply appears as a bubble with a motion.
    func chat(_ text: String) {
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
                    system: self.systemPrompt, messages: history, effort: "low", maxTokens: 4000, jsonSchema: PetReply.schema))
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
                        system: self.systemPrompt, messages: followUp, effort: "low", maxTokens: 4000, jsonSchema: PetReply.schema))
                    reply = PetReply.parse(turn.text)
                    reply.weatherCity = nil
                }
                let finalReply = reply, finalTurn = turn
                await MainActor.run {
                    var c = self.store.daily()
                    c.messages.append(StoredMessage(role: .assistant, text: finalReply.reply, raw: finalTurn.text,
                                                    wireProvider: provider.kind.rawValue, model: finalTurn.model))
                    self.store.save(c)
                    self.present(finalReply)
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

    private func present(_ reply: PetReply) {
        pet.setStatus(nil)
        pet.play(reply.motion)
        pet.say(reply.reply)
        if let remind = reply.remind { onRemind?(remind) }
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
                    system: self.systemPrompt, messages: [message], effort: "low", maxTokens: 2000, jsonSchema: PetReply.schema))
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
            (tr("唔……好舒服……", "Mm… that's nice…"), .sleepy),
        ]
        let (text, motion) = lines.randomElement()!
        pet.play(motion)
        pet.say(text)
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
    }

    /// Reminder delivery: local wording, optionally rephrased by the model in the persona's voice.
    func remind(_ text: String, motion: PetMotion) {
        wake()
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
        ]
        if hour >= 23 || hour < 5 { pool.append((tr("已经很晚了，早点休息吧……", "It's late, maybe get some sleep…"), .sleepy)) }
        if (14...16).contains(hour) { pool.append((tr("下午容易犯困，起来走走吧！", "Afternoons get sleepy, take a walk!"), .wave)) }
        let (text, motion) = pool.randomElement()!
        pet.play(motion)
        pet.say(text)
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
            pet.play(.wave)
        }
    }

    private func wake() {
        guard sleeping else { return }
        sleeping = false
        pet.setSleeping(false)
    }
}
