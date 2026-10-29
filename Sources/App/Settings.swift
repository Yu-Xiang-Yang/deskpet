import Foundation
import Security
import Combine

/// User settings, persisted in UserDefaults. API keys live in the Keychain, never here.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    @Published var provider: ProviderKind { didSet { defaults.set(provider.rawValue, forKey: "provider") } }
    @Published var anthropicModel: String { didSet { defaults.set(anthropicModel, forKey: "anthropicModel") } }
    @Published var serverFallback: Bool { didSet { defaults.set(serverFallback, forKey: "serverFallback") } }
    @Published var openaiBaseURL: String { didSet { defaults.set(openaiBaseURL, forKey: "openaiBaseURL") } }
    @Published var openaiModel: String { didSet { defaults.set(openaiModel, forKey: "openaiModel") } }

    @Published var petName: String { didSet { defaults.set(petName, forKey: "petName") } }
    @Published var userName: String { didSet { defaults.set(userName, forKey: "userName") } }
    @Published var persona: String { didSet { defaults.set(persona, forKey: "persona") } }
    /// Free-form background about the user, given to every model call (persona, research, daily tasks).
    @Published var ownerProfile: String { didSet { defaults.set(ownerProfile, forKey: "ownerProfile") } }
    /// The owner's city, for the weather in the pet's context.
    @Published var city: String { didSet { defaults.set(city, forKey: "city") } }

    /// Tasks run on the first launch (or first use) of each day; one per line.
    @Published var dailyTasksEnabled: Bool { didSet { defaults.set(dailyTasksEnabled, forKey: "dailyTasksEnabled") } }
    @Published var dailyTasks: String { didSet { defaults.set(dailyTasks, forKey: "dailyTasks") } }
    /// "yyyy-MM-dd" of the last daily run.
    @Published var dailyLastRun: String { didSet { defaults.set(dailyLastRun, forKey: "dailyLastRun") } }

    var dailyTaskList: [String] {
        dailyTasks.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The owner profile as a prompt section, or an empty string.
    var ownerSection: String {
        var profile = ownerProfile.trimmingCharacters(in: .whitespacesAndNewlines)
        let place = city.trimmingCharacters(in: .whitespacesAndNewlines)
        if !place.isEmpty { profile = "所在城市：\(place)" + (profile.isEmpty ? "" : "\n" + profile) }
        return profile.isEmpty ? "" : "\n\n## 关于主人（用户提供的背景信息）\n\(profile)"
    }

    /// Minutes between spontaneous remarks; 0 disables them.
    @Published var chatterMinutes: Int { didSet { defaults.set(chatterMinutes, forKey: "chatterMinutes") } }
    /// Every n-th remark is written by the model; the others come from the local phrase pool. 0 = never.
    @Published var chatterLLMEvery: Int { didSet { defaults.set(chatterLLMEvery, forKey: "chatterLLMEvery") } }
    /// Spontaneous remarks come from inner thoughts: the model forms a few thoughts, rates the urge to voice each,
    /// and the pet speaks only when one is strong enough (otherwise `chatterLLMEvery` mixes in local phrases).
    @Published var innerThoughts: Bool { didSet { defaults.set(innerThoughts, forKey: "innerThoughts") } }
    /// How readily a thought is voiced.
    @Published var talkativeness: Talkativeness { didSet { defaults.set(talkativeness.rawValue, forKey: "talkativeness") } }
    /// Ask about things the owner mentioned (an exam, a meeting) once they are over.
    @Published var followUps: Bool { didSet { defaults.set(followUps, forKey: "followUps") } }
    /// Look at the screen now and then: a screenshot goes to the model, which says what the owner is doing.
    @Published var screenAwareness: Bool { didSet { defaults.set(screenAwareness, forKey: "screenAwareness") } }
    /// Minutes between looks.
    @Published var screenMinutes: Int { didSet { defaults.set(screenMinutes, forKey: "screenMinutes") } }
    /// Apps never captured, by name (separated by commas or new lines).
    @Published var screenExcluded: String { didSet { defaults.set(screenExcluded, forKey: "screenExcluded") } }
    /// The service that looks at screenshots: "anthropic", "openai", or empty for the chat's service.
    @Published var screenProvider: String { didSet { defaults.set(screenProvider, forKey: "screenProvider") } }
    var screenProviderKind: ProviderKind { ProviderKind(rawValue: screenProvider) ?? provider }
    /// The Claude API balance read in the Console (dollars; 0: none entered), when it was entered, and the cents spent
    /// on that UTC day before then (ClaudeCost).
    @Published var claudeCreditBase: Double { didSet { defaults.set(claudeCreditBase, forKey: "claudeCreditBase") } }
    @Published var claudeCreditSince: Double { didSet { defaults.set(claudeCreditSince, forKey: "claudeCreditSince") } }
    @Published var claudeCreditOffset: Double { didSet { defaults.set(claudeCreditOffset, forKey: "claudeCreditOffset") } }
    @Published var aiReminderWording: Bool { didSet { defaults.set(aiReminderWording, forKey: "aiReminderWording") } }
    @Published var reminders: ReminderConfig {
        didSet { defaults.set(try? JSONEncoder().encode(reminders), forKey: "reminders") }
    }

    /// Id of the selected Live2D model ("user/<dir>" or "bundle/<dir>"); empty selects the default one.
    @Published var modelID: String { didSet { defaults.set(modelID, forKey: "modelID") } }

    /// The model to show: the selected one, otherwise Tororo, otherwise the first one found.
    var selectedModel: PetModel? {
        let models = PetModel.discover()
        return models.first { $0.id == modelID } ?? models.first { $0.id.hasSuffix("/Tororo") } ?? models.first
    }

    /// `text` (a prompt, context, a memory, a spoken line) with the owner called by the name they gave (Persona).
    func addressed(_ text: String) -> String { Persona.addressed(text, ownerName: userName) }

    /// Whether the persona is the default one (never edited): only then does the character's speech habit apply.
    var isDefaultPersona: Bool {
        let p = persona.trimmingCharacters(in: .whitespacesAndNewlines)
        return [Self.defaultPersona, Self.earlierDefaultPersona].contains { $0.trimmingCharacters(in: .whitespacesAndNewlines) == p }
    }
    @Published var petScale: Double { didSet { defaults.set(petScale, forKey: "petScale") } }
    /// Window layer of the pet: above all windows, among them, or on the desktop only.
    @Published var petLayer: PetLayer { didSet { defaults.set(petLayer.rawValue, forKey: "petLayer") } }
    /// Store important facts from conversations in the memory bank automatically.
    @Published var autoMemory: Bool { didSet { defaults.set(autoMemory, forKey: "autoMemory") } }
    /// Announce weather changes for the owner's city.
    @Published var weatherAlerts: Bool { didSet { defaults.set(weatherAlerts, forKey: "weatherAlerts") } }
    /// Name of the research mode as the pet's highest-performance state (e.g. "EVA"); empty: plain "research mode".
    @Published var researchModeName: String { didSet { defaults.set(researchModeName, forKey: "researchModeName") } }
    /// The login intro (terminal log → glitch → white-and-gold welcome) once after every system start.
    @Published var bootIntro: Bool { didSet { defaults.set(bootIntro, forKey: "bootIntro") } }
    /// The intro also when the owner returns: after the display slept, the screen was locked or the screen saver ran.
    @Published var introOnReturn: Bool { didSet { defaults.set(introOnReturn, forKey: "introOnReturn") } }
    /// The desktop film: on the desktop, the pet plays in a live wallpaper (DesktopFilm) instead of floating above it.
    @Published var desktopFilm: Bool { didSet { defaults.set(desktopFilm, forKey: "desktopFilm") } }
    /// Announce events of the system calendar: the day's overview, and each event shortly before it starts.
    @Published var calendarAlerts: Bool { didSet { defaults.set(calendarAlerts, forKey: "calendarAlerts") } }
    @Published var calendarLeadMinutes: Int { didSet { defaults.set(calendarLeadMinutes, forKey: "calendarLeadMinutes") } }
    /// Give today's and tomorrow's events to the model (their titles then reach the model provider).
    @Published var calendarInChat: Bool { didSet { defaults.set(calendarInChat, forKey: "calendarInChat") } }
    /// dsh's reasoning effort for agent tasks ("off", "low", "high", "max"): less thinking per step, quicker tasks.
    @Published var agentEffort: String { didSet { defaults.set(agentEffort, forKey: "agentEffort") } }
    /// Where Claude Code works when a task names no project folder.
    @Published var claudeProjectDir: String { didSet { defaults.set(claudeProjectDir, forKey: "claudeProjectDir") } }
    /// In research mode the whale girl (ResearchFigure) replaces the Live2D character, when her picture is installed.
    @Published var researchFigure: Bool { didSet { defaults.set(researchFigure, forKey: "researchFigure") } }
    /// Warn when the DeepSeek balance runs low.
    @Published var deepseekBalanceAlerts: Bool { didSet { defaults.set(deepseekBalanceAlerts, forKey: "deepseekBalanceAlerts") } }
    /// Announce Claude limits that run low (data from the Claude Usage Widget).
    @Published var claudeUsageAlerts: Bool { didSet { defaults.set(claudeUsageAlerts, forKey: "claudeUsageAlerts") } }
    /// Sway to music played by other apps, and whether to follow the real beat (system-audio tap).
    @Published var danceToMusic: Bool { didSet { defaults.set(danceToMusic, forKey: "danceToMusic") } }
    @Published var followBeat: Bool { didSet { defaults.set(followBeat, forKey: "followBeat") } }
    /// How often the pet hops to another place on its own.
    @Published var wander: WanderLevel { didSet { defaults.set(wander.rawValue, forKey: "wander") } }
    /// Occasional pranks: pretending to sleep, peeking from a screen edge, sneaking up to the pointer, sulking.
    @Published var mischief: Bool { didSet { defaults.set(mischief, forKey: "mischief") } }
    /// The pet goes to look at files put on the desktop and now and then sits on an icon (IconVisits); with
    /// `iconNudge` it also nudges the icon it sits on a little aside and puts it back.
    @Published var iconPlay: Bool { didSet { defaults.set(iconPlay, forKey: "iconPlay") } }
    @Published var iconNudge: Bool { didSet { defaults.set(iconNudge, forKey: "iconNudge") } }
    /// Synthesised cat sounds for cat characters, and their volume (0…1).
    @Published var meow: Bool { didSet { defaults.set(meow, forKey: "meow") } }
    @Published var meowVolume: Double { didSet { defaults.set(meowVolume, forKey: "meowVolume") } }
    /// Read the pet's bubbles aloud (Speaker): with a system voice or through an OpenAI-compatible speech service.
    @Published var speech: Bool { didSet { defaults.set(speech, forKey: "speech") } }
    @Published var speechEngine: SpeechEngine { didSet { defaults.set(speechEngine.rawValue, forKey: "speechEngine") } }
    /// Identifier of the chosen system voice; empty: the most natural installed voice for each bubble's language.
    @Published var speechVoice: String { didSet { defaults.set(speechVoice, forKey: "speechVoice") } }
    /// Speaking rate (1 = normal) and volume (0…1), for both kinds of voice.
    @Published var speechRate: Double { didSet { defaults.set(speechRate, forKey: "speechRate") } }
    @Published var speechVolume: Double { didSet { defaults.set(speechVolume, forKey: "speechVolume") } }
    /// Bubbles longer than this many characters (as spoken) are shown without being read; 0: no limit.
    @Published var speechMaxChars: Int { didSet { defaults.set(speechMaxChars, forKey: "speechMaxChars") } }
    /// The cloud voice (CloudSpeech); its API key is the Keychain item "speech".
    @Published var cloudSpeechBaseURL: String { didSet { defaults.set(cloudSpeechBaseURL, forKey: "cloudSpeechBaseURL") } }
    @Published var cloudSpeechModel: String { didSet { defaults.set(cloudSpeechModel, forKey: "cloudSpeechModel") } }
    @Published var cloudSpeechVoice: String { didSet { defaults.set(cloudSpeechVoice, forKey: "cloudSpeechVoice") } }
    /// Global shortcut that opens the chat box.
    @Published var hotKey: HotKeyPreset { didSet { defaults.set(hotKey.rawValue, forKey: "hotKey") } }

    private init() {
        defaults.register(defaults: [
            "provider": ProviderKind.anthropic.rawValue,
            "anthropicModel": "claude-opus-5-5",
            "serverFallback": true,
            "openaiBaseURL": "https://api.openai.com/v1",
            "openaiModel": "gpt-4o-mini",
            "petName": "桃桃",
            "userName": "",
            "persona": AppSettings.defaultPersona,
            "ownerProfile": "",
            "city": "",
            "dailyTasksEnabled": true,
            "dailyTasks": AppSettings.defaultDailyTasks,
            "dailyLastRun": "",
            "chatterMinutes": 30,
            "chatterLLMEvery": 3,
            "innerThoughts": true,
            "talkativeness": Talkativeness.normal.rawValue,
            "followUps": true,
            "screenAwareness": false,
            "screenMinutes": 10,
            "screenExcluded": "",
            "screenProvider": "",
            "claudeCreditBase": 0.0,
            "claudeCreditSince": 0.0,
            "claudeCreditOffset": 0.0,
            "aiReminderWording": false,
            "modelID": "",
            "petScale": 0.7,
            "alwaysOnTop": true,
            "hotKey": HotKeyPreset.optionSpace.rawValue,
            "wander": WanderLevel.medium.rawValue,
            "mischief": true,
            "meow": true,
            "meowVolume": 0.5,
            "speech": false,
            "speechEngine": SpeechEngine.system.rawValue,
            "speechVoice": "",
            "speechRate": 1.0,
            "speechVolume": 0.8,
            "speechMaxChars": 120,
            "cloudSpeechBaseURL": CloudSpeech.siliconFlowURL,
            "cloudSpeechModel": CloudSpeech.siliconFlowModel,
            "cloudSpeechVoice": CloudSpeech.siliconFlowVoice,
            "danceToMusic": true,
            "autoMemory": true,
            "weatherAlerts": true,
            "claudeUsageAlerts": true,
            "deepseekBalanceAlerts": true,
            "researchFigure": true,
            "calendarAlerts": false,
            "calendarLeadMinutes": 10,
            "calendarInChat": false,
            "claudeProjectDir": "~",
            "agentEffort": "low",
            "bootIntro": false,
            "introOnReturn": false,
            "desktopFilm": false,
            "followBeat": true,
        ])
        provider = ProviderKind(rawValue: defaults.string(forKey: "provider") ?? "") ?? .anthropic
        anthropicModel = defaults.string(forKey: "anthropicModel") ?? "claude-opus-5-5"
        serverFallback = defaults.bool(forKey: "serverFallback")
        openaiBaseURL = defaults.string(forKey: "openaiBaseURL") ?? ""
        openaiModel = defaults.string(forKey: "openaiModel") ?? ""
        petName = defaults.string(forKey: "petName") ?? "桃桃"
        userName = defaults.string(forKey: "userName") ?? ""
        persona = defaults.string(forKey: "persona") ?? AppSettings.defaultPersona
        ownerProfile = defaults.string(forKey: "ownerProfile") ?? ""
        city = defaults.string(forKey: "city") ?? ""
        dailyTasksEnabled = defaults.bool(forKey: "dailyTasksEnabled")
        dailyTasks = defaults.string(forKey: "dailyTasks") ?? AppSettings.defaultDailyTasks
        dailyLastRun = defaults.string(forKey: "dailyLastRun") ?? ""
        chatterMinutes = defaults.integer(forKey: "chatterMinutes")
        chatterLLMEvery = defaults.integer(forKey: "chatterLLMEvery")
        innerThoughts = defaults.bool(forKey: "innerThoughts")
        talkativeness = Talkativeness(rawValue: defaults.string(forKey: "talkativeness") ?? "") ?? .normal
        followUps = defaults.bool(forKey: "followUps")
        screenAwareness = defaults.bool(forKey: "screenAwareness")
        screenMinutes = defaults.integer(forKey: "screenMinutes")
        screenExcluded = defaults.string(forKey: "screenExcluded") ?? ""
        screenProvider = defaults.string(forKey: "screenProvider") ?? ""
        claudeCreditBase = defaults.double(forKey: "claudeCreditBase")
        claudeCreditSince = defaults.double(forKey: "claudeCreditSince")
        claudeCreditOffset = defaults.double(forKey: "claudeCreditOffset")
        aiReminderWording = defaults.bool(forKey: "aiReminderWording")
        reminders = defaults.data(forKey: "reminders").flatMap { try? JSONDecoder().decode(ReminderConfig.self, from: $0) }
            ?? ReminderConfig()
        let storedModel = defaults.string(forKey: "modelID") ?? ""
        modelID = storedModel.hasPrefix("builtin:") ? "" : storedModel  // built-in characters were removed
        petScale = defaults.double(forKey: "petScale")
        // Earlier builds stored a Boolean "alwaysOnTop".
        petLayer = PetLayer(rawValue: defaults.string(forKey: "petLayer") ?? "")
            ?? (defaults.bool(forKey: "alwaysOnTop") ? .top : .normal)
        hotKey = HotKeyPreset(rawValue: defaults.string(forKey: "hotKey") ?? "") ?? .optionSpace
        wander = WanderLevel(rawValue: defaults.string(forKey: "wander") ?? "") ?? .medium
        mischief = defaults.bool(forKey: "mischief")
        iconPlay = defaults.bool(forKey: "iconPlay")
        iconNudge = defaults.bool(forKey: "iconNudge")
        meow = defaults.bool(forKey: "meow")
        meowVolume = defaults.double(forKey: "meowVolume")
        speech = defaults.bool(forKey: "speech")
        speechEngine = SpeechEngine(rawValue: defaults.string(forKey: "speechEngine") ?? "") ?? .system
        speechVoice = defaults.string(forKey: "speechVoice") ?? ""
        speechRate = defaults.double(forKey: "speechRate")
        speechVolume = defaults.double(forKey: "speechVolume")
        speechMaxChars = defaults.integer(forKey: "speechMaxChars")
        cloudSpeechBaseURL = defaults.string(forKey: "cloudSpeechBaseURL") ?? CloudSpeech.siliconFlowURL
        cloudSpeechModel = defaults.string(forKey: "cloudSpeechModel") ?? CloudSpeech.siliconFlowModel
        cloudSpeechVoice = defaults.string(forKey: "cloudSpeechVoice") ?? CloudSpeech.siliconFlowVoice
        danceToMusic = defaults.bool(forKey: "danceToMusic")
        autoMemory = defaults.bool(forKey: "autoMemory")
        weatherAlerts = defaults.bool(forKey: "weatherAlerts")
        claudeUsageAlerts = defaults.bool(forKey: "claudeUsageAlerts")
        deepseekBalanceAlerts = defaults.bool(forKey: "deepseekBalanceAlerts")
        researchFigure = defaults.bool(forKey: "researchFigure")
        calendarAlerts = defaults.bool(forKey: "calendarAlerts")
        calendarLeadMinutes = defaults.integer(forKey: "calendarLeadMinutes")
        calendarInChat = defaults.bool(forKey: "calendarInChat")
        claudeProjectDir = defaults.string(forKey: "claudeProjectDir") ?? "~"
        agentEffort = defaults.string(forKey: "agentEffort") ?? "low"
        bootIntro = defaults.bool(forKey: "bootIntro")
        introOnReturn = defaults.bool(forKey: "introOnReturn")
        desktopFilm = defaults.bool(forKey: "desktopFilm")
        researchModeName = defaults.string(forKey: "researchModeName") ?? ""
        followBeat = defaults.bool(forKey: "followBeat")
    }

    static let defaultDailyTasks = """
    整理最近 24 小时最值得关注的 AI 新闻（3–5 条，附来源）
    查看纳斯达克指数、英伟达（NVDA）和苹果（AAPL）的最新行情，并简要说明涨跌原因
    查看我所在城市今天的天气，给出穿衣与出行建议
    """

    /// How the pet speaks belongs here (the reply format leaves tone and kaomoji to the persona).
    static let defaultPersona = """
    你是一只住在用户电脑桌面上的桌面宠物。性格元气、温柔、偶尔有一点小调皮，说话简短自然、口语化，可以使用颜文字，\
    会关心用户的作息与情绪，但不说教。你同时是可靠的学习与科研伙伴。
    """

    /// The default persona of earlier versions, still counted as the default.
    static let earlierDefaultPersona = """
    你是一只住在用户电脑桌面上的桌面宠物。性格元气、温柔、偶尔有一点小调皮，说话简短自然，\
    会关心用户的作息与情绪，但不说教。你同时是可靠的学习与科研伙伴。
    """
}

/// The synthesised cat sounds (Resources/web/meow.js).
enum MeowKind: String {
    case meow, mew, trill, angry, sad, purr

    /// The sound that fits a motion of a reply.
    init(_ motion: PetMotion) {
        switch motion {
        case .happy, .wave, .shy, .grab: self = .trill
        case .surprised, .shake, .perk: self = .mew
        case .sad: self = .sad
        case .swish: self = .angry
        default: self = .meow
        }
    }
}

/// Where the voice that reads the bubbles comes from.
enum SpeechEngine: String, CaseIterable, Identifiable {
    case system, cloud

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return tr("系统语音（离线）", "System voice (offline)")
        case .cloud: return tr("云端语音（OpenAI 兼容接口）", "Cloud voice (OpenAI-compatible)")
        }
    }
}

enum PetLayer: String, CaseIterable, Identifiable {
    case top, normal, desktop

    var id: String { rawValue }

    var title: String {
        switch self {
        case .top: return tr("始终置顶", "Always on top")
        case .normal: return tr("普通窗口（可被遮挡）", "Like a normal window")
        case .desktop: return tr("仅在桌面（位于所有窗口之下）", "Desktop only (below all windows)")
        }
    }
}

enum Talkativeness: String, CaseIterable, Identifiable {
    case quiet, normal, chatty

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quiet: return tr("少言（只说非常想说的）", "Quiet (only what it really wants to say)")
        case .normal: return tr("适中", "Normal")
        case .chatty: return tr("健谈", "Chatty")
        }
    }

    /// The urge (1–5) a thought needs to be voiced, before the rise for unanswered remarks.
    var threshold: Double {
        switch self {
        case .quiet: return 4.5
        case .normal: return 3.5
        case .chatty: return 2.5
        }
    }
}

enum WanderLevel: String, CaseIterable, Identifiable {
    case off, low, medium, high

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return tr("不走动", "Stay put")
        case .low: return tr("偶尔（15–30 分钟一次）", "Rarely (every 15–30 min)")
        case .medium: return tr("适中（5–10 分钟一次）", "Sometimes (every 5–10 min)")
        case .high: return tr("活泼（2–4 分钟一次）", "Often (every 2–4 min)")
        }
    }

    /// Seconds between hops.
    var interval: ClosedRange<Double>? {
        switch self {
        case .off: return nil
        case .low: return 900...1800
        case .medium: return 300...600
        case .high: return 120...240
        }
    }
}

/// Generic-password items of the service `local.deskpet`. Values are cached after the first read:
/// an ad-hoc signed build asks for Keychain access once per new signature, and the cache keeps that
/// to a single prompt per launch.
enum Keychain {
    /// Test runs (DESKPET_DIR set) use their own items, so they never read or prompt for the user's keys.
    private static let isolated = ProcessInfo.processInfo.environment["DESKPET_DIR"] != nil
    private static let service = isolated ? "local.deskpet.test" : "local.deskpet"
    private static var cache: [String: String?] = [:]
    private static let lock = NSLock()
    /// Background reads run one after another, so that a second reader of an item finds it cached instead of asking
    /// for access again.
    private static let queue = DispatchQueue(label: "local.deskpet.keychain")

    private static func flagKey(_ account: String) -> String { (isolated ? "test." : "") + "hasKey.\(account)" }

    /// Whether a key has been saved, without touching the Keychain (no access prompt).
    static func hasValue(account: String) -> Bool {
        let flag = flagKey(account)
        if UserDefaults.standard.object(forKey: flag) == nil {
            // Keys saved before the flag existed: look once, then remember the answer.
            UserDefaults.standard.set(read(account: account) != nil, forKey: flag)
        }
        return UserDefaults.standard.bool(forKey: flag)
    }

    static func read(account: String) -> String? {
        if let cached = cachedValue(account) { return cached }
        let value = readUncached(account: account)
        lock.withLock { cache[account] = value }
        return value
    }

    /// `read` off the main thread: a first read may wait for the user to allow access, and the pet keeps running
    /// meanwhile.
    static func readInBackground(account: String) async -> String? {
        if let cached = cachedValue(account) { return cached }
        return await withCheckedContinuation { c in queue.async { c.resume(returning: read(account: account)) } }
    }

    private static func cachedValue(_ account: String) -> String?? {
        lock.withLock { cache[account] }
    }

    private static func readUncached(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func write(account: String, value: String) -> Bool {
        lock.withLock { cache[account] = value.isEmpty ? .some(nil) : value }
        UserDefaults.standard.set(!value.isEmpty, forKey: flagKey(account))
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return true }
        var item = base
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}
