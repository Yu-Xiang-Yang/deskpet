import AppKit
import AVFoundation
import SwiftUI

final class SettingsWindowController {
    private var window: NSWindow?
    var onModelChange: (() -> Void)?
    var onTestReminders: (() -> Void)?
    var onRunDailyTasks: (() -> Void)?
    var onDigestMemories: ((@escaping (String) -> Void) -> Void)?
    var onCheckWeather: ((@escaping (String) -> Void) -> Void)?
    var onCheckCalendar: ((@escaping (String) -> Void) -> Void)?
    var onPreviewMeow: (() -> Void)?
    var onPreviewSpeech: ((@escaping (String) -> Void) -> Void)?
    var onCheckSpeechBalance: ((@escaping (String) -> Void) -> Void)?
    var onInstallSaver: (() -> String)?

    func show(tab: SettingsView.Tab = .general) {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(
                initialTab: tab,
                onModelChange: { [weak self] in self?.onModelChange?() },
                onTestReminders: { [weak self] in self?.onTestReminders?() },
                onRunDailyTasks: { [weak self] in self?.onRunDailyTasks?() },
                onDigestMemories: { [weak self] report in self?.onDigestMemories?(report) },
                onCheckWeather: { [weak self] report in self?.onCheckWeather?(report) },
                onCheckCalendar: { [weak self] report in self?.onCheckCalendar?(report) },
                onPreviewMeow: { [weak self] in self?.onPreviewMeow?() },
                onPreviewSpeech: { [weak self] outcome in self?.onPreviewSpeech?(outcome) },
                onCheckSpeechBalance: { [weak self] report in self?.onCheckSpeechBalance?(report) },
                onInstallSaver: { [weak self] in self?.onInstallSaver?() ?? "" }))
            let w = NSWindow(contentViewController: hosting)
            w.title = tr("桌宠设置", "DeskPet Settings")
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    enum Tab: Hashable { case general, owner, memory, model, reminders, daily }

    @ObservedObject private var settings = AppSettings.shared
    @State var initialTab: Tab
    var onModelChange: () -> Void
    var onTestReminders: () -> Void
    var onRunDailyTasks: () -> Void
    var onDigestMemories: (@escaping (String) -> Void) -> Void
    var onCheckWeather: (@escaping (String) -> Void) -> Void
    var onCheckCalendar: (@escaping (String) -> Void) -> Void
    var onPreviewMeow: () -> Void
    var onPreviewSpeech: (@escaping (String) -> Void) -> Void
    var onCheckSpeechBalance: (@escaping (String) -> Void) -> Void
    var onInstallSaver: () -> String
    @State private var saverResult = ""
    @State private var voices = Speaker.installedVoices
    @State private var speechKey = Keychain.hasValue(account: "speech") ? (Keychain.read(account: "speech") ?? "") : ""
    @State private var speechResult = ""
    @State private var speechBalance = ""
    @State private var voiceCache = VoiceCache.summary

    @ObservedObject private var memory = MemoryStore.shared
    @ObservedObject private var mind = MindState.shared
    @ObservedObject private var screen = ScreenWatcher.shared
    @State private var lookResult = ""
    @State private var screenPermitted = ScreenWatcher.permitted
    @State private var newMemory = ""
    @State private var confirmClear = false
    @State private var digestResult = ""
    @State private var weatherResult = ""
    @State private var calendarResult = ""

    @State private var anthropicKey = Keychain.hasValue(account: "anthropic") ? (Keychain.read(account: "anthropic") ?? "") : ""
    @State private var openaiKey = Keychain.hasValue(account: "openai") ? (Keychain.read(account: "openai") ?? "") : ""
    @State private var adminKey = Keychain.hasValue(account: "anthropic-admin") ? (Keychain.read(account: "anthropic-admin") ?? "") : ""
    @State private var creditInput = ""
    @State private var costResult = ""
    @ObservedObject private var claudeCost = ClaudeCostWatcher.shared
    @State private var testResult = ""
    @State private var testing = false
    @State private var mealTimes = AppSettings.shared.reminders.mealTimes.joined(separator: ", ")
    @State private var models = PetModel.discover()
    @State private var launchAtLogin = LoginItem.enabled
    @State private var language = L10n.preference

    private struct Preset { let name: String; let url: String; let model: String }
    private let presets = [
        Preset(name: "OpenAI", url: "https://api.openai.com/v1", model: "gpt-4o-mini"),
        Preset(name: "DeepSeek", url: "https://api.deepseek.com/v1", model: "deepseek-chat"),
        Preset(name: "通义千问 (DashScope)", url: "https://dashscope.aliyuncs.com/compatible-mode/v1", model: "qwen-plus"),
        Preset(name: "Moonshot (Kimi)", url: "https://api.moonshot.cn/v1", model: "moonshot-v1-8k"),
        Preset(name: "Ollama (本地)", url: "http://localhost:11434/v1", model: "qwen2.5"),
    ]

    var body: some View {
        TabView(selection: $initialTab) {
            general.tabItem { Label(tr("通用", "General"), systemImage: "pawprint") }.tag(Tab.general)
            owner.tabItem { Label(tr("主人信息", "About me"), systemImage: "person.crop.circle") }.tag(Tab.owner)
            model.tabItem { Label(tr("模型", "Model"), systemImage: "brain") }.tag(Tab.model)
            reminders.tabItem { Label(tr("提醒", "Reminders"), systemImage: "alarm") }.tag(Tab.reminders)
            daily.tabItem { Label(tr("每日任务", "Daily tasks"), systemImage: "sun.max") }.tag(Tab.daily)
            memoryTab.tabItem { Label(tr("记忆库", "Memory"), systemImage: "brain.head.profile") }.tag(Tab.memory)
        }
        .padding(16)
        .frame(width: 560, height: 520)
    }

    // MARK: General

    private var general: some View {
        Form {
            Section(tr("角色", "Character")) {
                TextField(tr("桌宠名字", "Pet name"), text: $settings.petName)
                TextField(tr("对你的称呼（可留空）", "How the pet addresses you (optional)"), text: $settings.userName)
                TextField(tr("科研模式名称（可留空，如 EVA）", "Research mode name (optional, e.g. EVA)"), text: $settings.researchModeName)
                VStack(alignment: .leading, spacing: 4) {
                    Text(tr("人设", "Persona")).font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $settings.persona)
                        .font(.system(size: 12))
                        .frame(height: 80)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                    Button(tr("恢复默认人设", "Reset persona")) { settings.persona = AppSettings.defaultPersona }
                        .controlSize(.small)
                }
            }
            Section(tr("外观", "Appearance")) {
                Picker(tr("形象", "Character"), selection: $settings.modelID) {
                    Text(tr("默认（\(settings.selectedModel?.name ?? "无")）", "Default (\(settings.selectedModel?.name ?? "none"))")).tag("")
                    ForEach(models) { m in Text(m.name).tag(m.id) }
                }
                .onChange(of: settings.modelID) { onModelChange() }
                if let credit = settings.selectedModel?.map?["credit"]?.string {
                    Text(credit).font(.caption).foregroundStyle(.secondary)
                }
                if models.isEmpty || !PetModel.cubismCoreInstalled {
                    Text(tr("未找到 Live2D 模型或 Cubism Core，桌宠无法显示。请把模型和 live2dcubismcore.min.js 放入模型文件夹（见 README）。",
                            "No Live2D model or Cubism Core found, so the pet cannot be shown. Put a model and live2dcubismcore.min.js into the models folder (see README)."))
                        .font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Button(tr("打开模型文件夹", "Open models folder")) {
                        NSWorkspace.shared.open(AppPaths.ensure(AppPaths.userModelsDir))
                    }
                    Button(tr("重新扫描", "Rescan")) { models = PetModel.discover(); onModelChange() }
                }
                Slider(value: $settings.petScale, in: 0.4...1.4, step: 0.05) {
                    Text(tr("大小", "Size") + " \(Int((settings.petScale * 100).rounded()))%")
                }
                Toggle(tr("听到音乐时跟着摇摆", "Sway to music"), isOn: $settings.danceToMusic)
                Toggle(tr("跟随真实节拍（需允许“系统音频录制”）", "Follow the real beat (needs “System Audio Recording”)"), isOn: $settings.followBeat)
                    .disabled(!settings.danceToMusic)
                Picker(tr("自由走动", "Wandering"), selection: $settings.wander) {
                    ForEach(WanderLevel.allCases) { Text($0.title).tag($0) }
                }
                Text(tr("打字时不会走动，停手后再走。", "The pet does not move while you type; it waits for a pause."))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(tr("淘气行为", "Mischief"), isOn: $settings.mischief)
                Text(tr("偶尔装睡、躲到屏幕边偷看、偷偷溜到鼠标旁，摸头太多次会闹脾气；每 8–15 分钟至多一次，打字时不会发生，点一下桌宠即可结束。",
                        "Now and then the pet pretends to sleep, peeks out from a screen edge or sneaks up to the pointer, and sulks when petted too often; at most once every 8–15 minutes, never while you type, and a click ends it."))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(tr("和桌面图标互动", "Play with desktop icons"), isOn: $settings.iconPlay)
                Toggle(tr("允许拨动图标（离开前放回原处）", "May nudge icons (put back before leaving)"), isOn: $settings.iconNudge)
                    .disabled(!settings.iconPlay)
                Text(tr("桌面上出现新文件（下载、截图）时，桌宠跳到它的图标上嗅一嗅、拍一拍并说一句；平时每 6–12 分钟也会自己去图标上坐一会儿。只去没被窗口挡住、位于菜单栏下方足够低处的图标；第一次会请求“控制访达”的权限，用于读取图标位置。",
                        "When a new file appears on the desktop (a download, a screenshot), the pet jumps onto its icon, sniffs it, paws at it and says something; every 6–12 minutes it also goes to sit on an icon on its own. Only icons no window covers and far enough below the menu bar; the first time, macOS asks to let DeskPet control Finder, to read where the icons are."))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(tr("猫叫", "Cat sounds"), isOn: $settings.meow)
                if settings.meow {
                    HStack {
                        Text(tr("音量", "Volume"))
                        Slider(value: $settings.meowVolume, in: 0.05...1) { editing in
                            if !editing { onPreviewMeow() }
                        }
                    }
                }
                Text(tr("摸头时打呼噜，打招呼、提醒、淘气和部分回复时喵一声（真猫录音，仅猫形象）。", "Purrs when petted and meows when greeting, reminding, up to mischief and with some replies (real recordings, cat characters only)."))
                    .font(.caption).foregroundStyle(.secondary)
                Picker(tr("显示层级", "Window layer"), selection: $settings.petLayer) {
                    ForEach(PetLayer.allCases) { Text($0.title).tag($0) }
                }
                Toggle(tr("桌面影院（动态墙纸）", "Desktop film (live wallpaper)"), isOn: $settings.desktopFilm)
                Text(tr("桌面上没有其它窗口遮挡（覆盖不足 1/5 屏幕）时，桌宠走进墙纸，以全屏电影的方式出演：胶片颗粒、随时段变化的光影、镜头推拉与剪辑，说的话以字幕呈现；它会站在小组件和窗口遮不到的地方，不时跳上桌面图标、躲到小组件后面探头，并说说上面显示的内容。指针移动时它会看过来；点头部是摸头，点身体在字幕处打开聊天框，点空白桌面它会望向那里。窗口回到桌面上时画面定格为墙纸，桌宠回到原处。",
                        "When no other windows cover the desktop (less than a fifth of the screen), the pet steps into the wallpaper and plays in a full-screen film: film grain, light that follows the time of day, camera moves and cuts, its words as subtitles; it stands where no widget or window hides it, and now and then jumps onto a desktop icon or peeks out from behind a widget and remarks on what it shows. It looks at the pointer; a click on its head pets it, on its body opens the chat box where the subtitles are, on the empty desktop makes it look there. When windows cover the desktop again, the picture freezes as the wallpaper and the pet returns."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            voiceSection
            Section(tr("Claude Code（开发任务）", "Claude Code (development work)")) {
                TextField(tr("默认项目目录", "Default project folder"), text: $settings.claudeProjectDir)
                Text(tr("说“让 Claude 来做……”或交代开发类任务时，桌宠在“终端”里打开 Claude Code 会话（使用你本机登录的 Claude 账号，与上面聊天所用的模型无关），任务作为第一句话发出；没说项目时在这个目录里工作。",
                        "When you ask for Claude or give development work, the pet opens a Claude Code session in Terminal (with the Claude account signed in on this Mac, independent of the chat model) and sends the task as its first message; without a named project it works in this folder."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(tr("系统", "System")) {
                Picker(tr("语言", "Language"), selection: $language) {
                    ForEach(LanguagePreference.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: language) { _, new in L10n.preference = new }
                Picker(tr("呼出聊天框快捷键", "Chat shortcut"), selection: $settings.hotKey) {
                    ForEach(HotKeyPreset.allCases) { Text($0.title).tag($0) }
                }
                Text(tr("单击桌宠身体也可打开聊天框；单击头部是摸头。", "A click on the pet's body also opens the chat box; a click on its head pets it."))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(tr("科研模式使用鲸鱼娘形象", "Whale girl as the research-mode character"), isOn: $settings.researchFigure)
                    .disabled(!ResearchFigure.installed)
                Text(ResearchFigure.installed ? ResearchFigure.credit
                     : tr("未找到鲸鱼娘图片（~/Library/Application Support/DeskPet/characters/whale-girl）。", "The whale girl picture is not installed."))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(tr("开机动画", "Login intro"), isOn: $settings.bootIntro)
                Text(tr("每次开机后，桌宠第一次启动时全屏播放约 6 秒：终端自检 → 故障转场 → 白金欢迎页；按任意键或点击可跳过。右键菜单可随时预览。",
                        "After each system start, the pet's first launch plays a 6-second full-screen intro: terminal log → glitch → white-and-gold welcome; any key or click skips it. The context menu plays it any time."))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(tr("熄屏、锁屏或屏保结束后也播放", "Also after the display slept, the screen was locked or the screen saver ran"),
                       isOn: $settings.introOnReturn)
                    .disabled(!settings.bootIntro)
                HStack {
                    Button(tr("安装 / 更新屏保", "Install / update screen saver")) { saverResult = onInstallSaver() }
                    Text(saverResult).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Text(tr("屏保与开机动画同一风格：桌宠 AI 待命画面，时钟和头像位置与锁屏对齐，显示任务日志与系统状态。",
                        "The screen saver matches the intro: the pet AI on standby, clock and user picture aligned with the lock screen, with a task log and system status."))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(tr("登录时启动", "Launch at login"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        if !LoginItem.set(on) { launchAtLogin = LoginItem.enabled }
                        UserDefaults.standard.set(LoginItem.enabled, forKey: "launchAtLogin")
                    }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Voice

    /// The system voices offered in the picker: Chinese and English ones that do not sound synthetic, best first.
    private var systemVoices: [SpeechVoice] {
        (SpeechVoices.ranked(voices, for: "zh-CN") + SpeechVoices.ranked(voices, for: "en-US")).filter { !SpeechVoices.isSynthetic($0) }
    }

    private func voiceTitle(_ v: SpeechVoice) -> String {
        let quality = v.quality >= 3 ? tr("高级", "Premium") : v.quality == 2 ? tr("增强", "Enhanced") : tr("标准", "Standard")
        return "\(v.name)（\(v.language) · \(quality)）"
    }

    private func checkSpeechBalance() {
        guard !speechKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            speechBalance = tr("填写 API key 后显示", "Shown once a key is entered")
            return
        }
        speechBalance = tr("查询中…", "Checking…")
        onCheckSpeechBalance { speechBalance = $0 }
    }

    private var voiceSection: some View {
        Section(tr("语音", "Voice")) {
            Toggle(tr("朗读气泡", "Read bubbles aloud"), isOn: $settings.speech)
            Text(tr("桌宠说的气泡会读出来，气泡随声音一起出现，说话时嘴巴跟着动；你发消息时它会停下。执行代理与 Claude Code 的交办、汇报和报错只显示不读。",
                    "The pet's bubbles are read aloud and appear with their voice, the mouth moving; it stops when you send a message. The agent's and Claude Code's hand-overs, reports and errors are shown, not read."))
                .font(.caption).foregroundStyle(.secondary)
            if settings.speech {
                Picker(tr("长文不读", "Long text"), selection: $settings.speechMaxChars) {
                    ForEach([60, 120, 200, 400], id: \.self) { Text(tr("超过 \($0) 字只显示", "Over \($0) characters: shown only")).tag($0) }
                    Text(tr("不限（科研回答只读开头约 \(Speaker.answerLimit) 字）", "No limit (research answers up to about \(Speaker.answerLimit) characters)")).tag(0)
                }
                Picker(tr("声音来源", "Voice source"), selection: $settings.speechEngine) {
                    ForEach(SpeechEngine.allCases) { Text($0.title).tag($0) }
                }
                if settings.speechEngine == .system {
                    Picker(tr("声音", "Voice"), selection: $settings.speechVoice) {
                        Text(tr("自动（每种语言中最自然的已安装声音）", "Automatic (the most natural installed voice per language)")).tag("")
                        ForEach(systemVoices, id: \.identifier) { Text(voiceTitle($0)).tag($0.identifier) }
                    }
                    if !SpeechVoices.hasNatural(voices, language: "zh-CN") {
                        Text(tr("本机只有标准音质的中文声音，听起来偏机械。可在 系统设置 → 辅助功能 → 阅读与朗读（macOS 15 及更早为“朗读内容”）→ 系统声音 → 管理声音 中下载中文声音的高级（Premium）或增强（Enhanced）版本（免费，离线使用），下载后这里会自动选用。",
                                "Only standard-quality Chinese voices are installed, which sound mechanical. Download the Premium or Enhanced version of a Chinese voice under System Settings → Accessibility → Read & Speak (Spoken Content up to macOS 15) → System Voice → Manage Voices (free, works offline); it is then chosen here automatically."))
                            .font(.caption).foregroundStyle(.orange)
                        Button(tr("打开系统朗读设置", "Open the system's speech settings")) {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                } else {
                    Menu(tr("预设", "Presets")) {
                        Button(tr("硅基流动 CosyVoice2（中文最自然）", "SiliconFlow CosyVoice2 (most natural Chinese)")) {
                            settings.cloudSpeechBaseURL = CloudSpeech.siliconFlowURL
                            settings.cloudSpeechModel = CloudSpeech.siliconFlowModel
                            settings.cloudSpeechVoice = CloudSpeech.siliconFlowVoice
                        }
                        Button("OpenAI gpt-4o-mini-tts") {
                            settings.cloudSpeechBaseURL = "https://api.openai.com/v1"
                            settings.cloudSpeechModel = "gpt-4o-mini-tts"
                            settings.cloudSpeechVoice = "coral"
                        }
                        Button(tr("本机千问 Qwen3-TTS（离线，免费）", "Local Qwen3-TTS (offline, free)")) {
                            settings.cloudSpeechBaseURL = LocalVoiceServer.baseURL
                            settings.cloudSpeechModel = "qwen3-tts"
                            settings.cloudSpeechVoice = "default"
                        }
                    }
                    if CloudSpeech.isLocalVoice(baseURL: settings.cloudSpeechBaseURL) {
                        Text(LocalVoiceServer.installed
                             ? tr("本机千问语音：由桌宠自动启动，模型闲置 10 分钟后卸载、下次说话时重新加载（约 3 秒）；声音为 local-voice/voices 中的参考录音，不联网、不计费。",
                                  "Local Qwen3-TTS: started by the pet, its model unloaded after 10 idle minutes and loaded again for the next words (about 3 s); the voice is the reference recording in local-voice/voices; no network, no charge.")
                             : tr("本机语音尚未安装：在终端运行 scripts/local-voice/install.sh <参考录音.wav> \"<录音中的原话>\"（需 Apple 芯片），在此之前由系统语音朗读。",
                                  "The local voice is not installed: run scripts/local-voice/install.sh <reference.wav> \"<what it says>\" in Terminal (Apple Silicon); until then the system voice reads."))
                            .font(.caption).foregroundStyle(LocalVoiceServer.installed ? Color.secondary : Color.orange)
                    }
                    TextField("Base URL", text: $settings.cloudSpeechBaseURL)
                    TextField(tr("模型", "Model"), text: $settings.cloudSpeechModel)
                    TextField(tr("声音", "Voice"), text: $settings.cloudSpeechVoice)
                    SecureField("API key", text: $speechKey)
                        .onChange(of: speechKey) { _, key in
                            Keychain.write(account: "speech", value: key.trimmingCharacters(in: .whitespacesAndNewlines))
                            speechBalance = key.isEmpty ? tr("填写 API key 后显示", "Shown once a key is entered") : tr("点“刷新”查询", "Refresh to check")
                        }
                    HStack {
                        Text(tr("本地缓存", "Saved on this Mac"))
                        Spacer()
                        Text(voiceCache).foregroundStyle(.secondary)
                        Button(tr("清空", "Clear")) { VoiceCache.clear(); voiceCache = VoiceCache.summary }
                    }
                    .onAppear { voiceCache = VoiceCache.summary }
                    Text(tr("合成过的语音按“文字、模型、声音、语速”保存在本机（至多 50 MB，先删最久未用的），同一句话再说时直接播放，不再请求、不再计费，没网也能读。",
                            "Spoken pieces are saved on this Mac by text, model, voice and rate (up to 50 MB, least recently used first out); the same line plays from disk next time, without a request or a charge, also offline."))
                        .font(.caption).foregroundStyle(.secondary)
                    if CloudSpeechBalance.endpoint(baseURL: settings.cloudSpeechBaseURL) != nil {
                        HStack {
                            Text(tr("余额", "Balance"))
                            Spacer()
                            Text(speechBalance).foregroundStyle(.secondary).lineLimit(2)
                            Button(tr("刷新", "Refresh")) { checkSpeechBalance() }
                            Button(tr("控制台", "Console")) {
                                if let url = CloudSpeechBalance.console(baseURL: settings.cloudSpeechBaseURL) { NSWorkspace.shared.open(url) }
                            }
                        }
                        .onAppear { checkSpeechBalance() }
                    }
                    Text(tr("每个气泡的文字会发送到该服务合成语音，按量计费；未填 key 或请求失败时改用系统语音。硅基流动的预设声音写作“模型:名字”：diana 欢快女声、claire 温柔女声、anna 沉稳女声、bella 激情女声，alex、benjamin、charles、david 为男声。",
                            "The text of every bubble is sent to this service to be spoken, billed by use; without a key or when a request fails, the system voice speaks instead. SiliconFlow's preset voices are written \"model:name\": diana cheerful, claire gentle, anna calm, bella passionate (female); alex, benjamin, charles, david (male)."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Slider(value: $settings.speechRate, in: 0.7...1.4, step: 0.05) {
                    Text(tr("语速", "Rate") + " \(Int((settings.speechRate * 100).rounded()))%")
                }
                Slider(value: $settings.speechVolume, in: 0.1...1) { Text(tr("音量", "Volume")) }
                HStack {
                    Button(tr("试听", "Listen")) {
                        speechResult = tr("朗读中…", "Speaking…")
                        onPreviewSpeech { result in speechResult = result }
                    }
                    Text(speechResult).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .onAppear { voices = Speaker.installedVoices }
        .onReceive(NotificationCenter.default.publisher(for: AVSpeechSynthesizer.availableVoicesDidChangeNotification)) { _ in
            voices = Speaker.installedVoices
        }
    }

    // MARK: Owner

    private var owner: some View {
        Form {
            Section {
                TextField(tr("所在城市（用于天气，如：杭州）", "City (for the weather, e.g. Hangzhou)"), text: $settings.city)
            } footer: {
                Text(tr("填写后，桌宠聊天时会知道当地天气（每 30 分钟更新，来自 Open-Meteo）；问其它城市的天气它会现查。",
                        "With a city set, the pet knows the local weather while chatting (refreshed every 30 minutes, from Open-Meteo); other cities are looked up on demand."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                TextEditor(text: $settings.ownerProfile)
                    .font(.system(size: 12.5))
                    .frame(height: 200)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                    .overlay(alignment: .topLeading) {
                        if settings.ownerProfile.isEmpty {
                            Text(tr("""
                            例如：
                            我是一名材料科学方向的博士生，研究钙钛矿太阳能电池，常用 Python 做数据分析。
                            喜欢猫和摄影，晚上效率高，经常忘记吃午饭。
                            关注的股票：英伟达（NVDA）、腾讯（0700.HK）、宁德时代（300750）。
                            """, """
                            For example:
                            PhD student in materials science (perovskite solar cells), uses Python for data analysis.
                            Likes cats and photography, works best at night, often forgets lunch.
                            Stocks I follow: NVDA, 0700.HK, 300750.
                            """))
                            .font(.system(size: 12.5))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 6).padding(.vertical, 8)
                            .allowsHitTesting(false)
                        }
                    }
            } header: {
                Text(tr("关于主人", "About me"))
            } footer: {
                Text(tr("身份与研究方向、兴趣爱好、作息习惯、关注的领域与股票等。这些信息会作为背景提供给闲聊、科研回答和每日任务，仅保存在本机，并随每次请求发送给所选的模型服务。",
                        "Background such as your work and research field, interests, routine, and the topics or stocks you follow. It is given to chats, research answers and daily tasks; it is stored on this Mac and sent with each request to the selected model provider."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Daily tasks

    private var daily: some View {
        Form {
            Section {
                Toggle(tr("每天第一次使用时自动执行", "Run on the first use of each day"), isOn: $settings.dailyTasksEnabled)
                VStack(alignment: .leading, spacing: 4) {
                    Text(tr("任务（每行一项）", "Tasks (one per line)")).font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $settings.dailyTasks)
                        .font(.system(size: 12.5))
                        .frame(height: 170)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                }
                HStack {
                    Button(tr("立即执行一次", "Run now"), action: onRunDailyTasks)
                    Button(tr("恢复示例任务", "Restore examples")) { settings.dailyTasks = AppSettings.defaultDailyTasks }
                    Spacer()
                    Text(settings.dailyLastRun.isEmpty ? tr("尚未执行", "Not run yet")
                         : tr("上次执行：", "Last run: ") + settings.dailyLastRun)
                        .font(.caption).foregroundStyle(.secondary)
                }
            } footer: {
                Text(tr("当天第一次启动、或当天第一次有操作时，桌宠会依次执行这些任务：用检索工具查找最新新闻、行情或文献，以气泡告诉你要点，完整内容保存为消息列表中的“每日简报”。也可以在右键菜单中选择“执行每日任务”。",
                        "On the first launch or first activity of each day the pet runs these tasks with its search tools (news, quotes, papers), tells you the key points in bubbles, and saves the full results as a “Daily brief” in the message list. You can also choose “Run daily tasks” from the right-click menu."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Memory

    private var memoryTab: some View {
        Form {
            Section {
                Toggle(tr("从对话中自动记住重要信息", "Remember important things from conversations"), isOn: $settings.autoMemory)
                HStack {
                    TextField(tr("手动添加一条记忆，如：主人对花生过敏", "Add a memory, e.g. I am allergic to peanuts"), text: $newMemory)
                        .onSubmit(addMemory)
                    Button(tr("添加", "Add"), action: addMemory).disabled(newMemory.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                HStack {
                    Button(tr("立即整理最近的对话", "Consolidate recent chats now")) {
                        digestResult = tr("整理中…", "Consolidating…")
                        onDigestMemories { digestResult = $0 }
                    }
                    .disabled(!settings.autoMemory)
                    Text(digestResult).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            } footer: {
                Text(tr("记忆分为三层：长期事实（偏好、过敏、重要日期等，对话中随时记下）、经历（每段对话结束约 10 分钟后整理出当天发生的事）与印象（从多段经历中归纳）。手动添加的记忆与重要的事实始终作为背景；其余记忆按与当前话题的相关程度、重要程度与新近程度检索。经历与印象若不再被提起会逐渐淡忘，每被提起一次记得更久。记忆保存在本机，所选的模型服务会收到与话题相关的部分。对桌宠说“忘掉……”也可删除相关记忆。",
                        "Memories come in three layers: facts (preferences, allergies, dates; noted during chats), episodes (what happened, consolidated about 10 minutes after a conversation) and impressions (drawn from several episodes). Manual entries and important facts are always in the background; the rest are recalled by relevance to the topic, importance and recency. Episodes and impressions fade unless they come up again; each recall makes them last longer. Memories stay on this Mac; the model service receives those relevant to the topic. Saying “forget …” to the pet removes matching memories."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            memorySection(.fact, title: tr("长期事实", "Facts"))
            memorySection(.reminder, title: tr("提醒与日程", "Reminders and events"))
            memorySection(.episode, title: tr("经历", "Episodes"))
            memorySection(.insight, title: tr("印象", "Impressions"))
            Section {
                if memory.items.isEmpty {
                    Text(tr("还没有记忆。", "No memories yet.")).foregroundStyle(.secondary)
                } else {
                    Button(tr("清空全部记忆…", "Clear all memories…"), role: .destructive) { confirmClear = true }
                        .confirmationDialog(tr("确定清空全部 \(memory.items.count) 条记忆？此操作无法撤销。", "Clear all \(memory.items.count) memories? This cannot be undone."),
                                            isPresented: $confirmClear) {
                            Button(tr("清空", "Clear"), role: .destructive) { memory.removeAll() }
                        }
                }
            } footer: {
                if mind.faded > 0 {
                    Text(tr("已淡忘 \(mind.faded) 条久未提起的经历与印象。", "\(mind.faded) episodes and impressions faded away."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section(tr("最近的念头", "Recent thoughts")) {
                if mind.log.isEmpty {
                    Text(tr("还没有念头。主动闲聊开启后，桌宠会不时想一想，只有念头足够强烈时才开口。", "No thoughts yet. With spontaneous remarks on, the pet thinks now and then and speaks only when a thought is strong enough."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(mind.log.prefix(12)) { e in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(timeStamp(e.date) + " · " + triggerTitle(e.trigger)).font(.caption2).foregroundStyle(.secondary)
                        ForEach(Array(e.thoughts.enumerated()), id: \.offset) { _, t in
                            Text(t).font(.system(size: 11.5)).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        if let said = e.said {
                            Text(tr("说出口：", "Said: ") + said).font(.system(size: 12.5)).textSelection(.enabled)
                        } else if let note = e.note {
                            Text(note).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// The memories of one kind, newest first, with their day, importance, retention and a pending follow-up.
    @ViewBuilder
    private func memorySection(_ kind: MemoryKind, title: String) -> some View {
        let items = memory.items.filter { $0.kind == kind }.sorted { $0.created > $1.created }
        if !items.isEmpty {
            Section(title + tr("（\(items.count) 条）", " (\(items.count))")) {
                ForEach(items) { m in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.text).font(.system(size: 12.5)).textSelection(.enabled)
                            Text(memoryDetail(m)).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { memory.remove(m.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .help(tr("删除", "Delete"))
                    }
                }
            }
        }
    }

    private func memoryDetail(_ m: Memory) -> String {
        var parts = [ReminderRules.dayStamp(m.created, .current)]
        if m.source == "manual" { parts.append(tr("手动添加", "added manually")) }
        parts.append(tr("重要度 \(m.importance)", "importance \(m.importance)"))
        if m.kind != .fact, m.source != "manual" {
            parts.append(tr("记忆强度 \(Int((m.retention(at: Date()) * 100).rounded()))%", "retention \(Int((m.retention(at: Date()) * 100).rounded()))%"))
        }
        if m.recalls > 0 { parts.append(tr("被提起 \(m.recalls) 次", "recalled \(m.recalls)×")) }
        if let at = m.followUp { parts.append(tr("打算 \(timeStamp(at)) 问问", "to ask about at \(timeStamp(at))")) }
        return parts.joined(separator: " · ")
    }

    private func timeStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: date)
    }

    private func triggerTitle(_ trigger: String) -> String {
        switch trigger {
        case "idle": return tr("闲时的念头", "Idle thought")
        case "follow_up": return tr("跟进到期", "Follow-up due")
        case "returned": return tr("主人回来时", "Owner returned")
        case "digest": return tr("整理记忆", "Consolidation")
        default: return trigger
        }
    }

    private func addMemory() {
        if memory.add(newMemory, source: "manual") { newMemory = "" }
    }

    // MARK: Model

    private var model: some View {
        Form {
            Picker(tr("服务", "Provider"), selection: $settings.provider) {
                ForEach(ProviderKind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            // A service is shown when the chat uses it, or when watching the screen does.
            if settings.provider == .anthropic || (settings.screenAwareness && settings.screenProviderKind == .anthropic) {
                Section(settings.provider == .anthropic ? "Claude" : tr("Claude（观察屏幕使用）", "Claude (for watching the screen)")) {
                    SecureField("API key", text: $anthropicKey)
                        .onChange(of: anthropicKey) { _, key in Keychain.write(account: "anthropic", value: key.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    TextField(tr("模型", "Model"), text: $settings.anthropicModel)
                    Toggle(tr("拒答时由服务端自动回退到其它模型", "Server-side fallback on refusals"), isOn: $settings.serverFallback)
                    Text(tr("默认模型 claude-opus-5-5；科研模式使用服务端 web_search 工具检索网页，另提供 arXiv 与 Semantic Scholar 检索。",
                            "Default model claude-opus-5-5. Research mode uses the server-side web_search tool plus arXiv and Semantic Scholar search."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                claudeCostSection
            }
            if settings.provider == .openai || (settings.screenAwareness && settings.screenProviderKind == .openai) {
                Section(settings.provider == .openai ? tr("OpenAI 兼容接口", "OpenAI-compatible")
                        : tr("OpenAI 兼容接口（观察屏幕使用）", "OpenAI-compatible (for watching the screen)")) {
                    Menu(tr("预设", "Presets")) {
                        ForEach(presets, id: \.name) { p in
                            Button(p.name) { settings.openaiBaseURL = p.url; settings.openaiModel = p.model }
                        }
                    }
                    TextField("Base URL", text: $settings.openaiBaseURL)
                    TextField(tr("模型", "Model"), text: $settings.openaiModel)
                    SecureField(tr("API key（本地服务可留空）", "API key (optional for local servers)"), text: $openaiKey)
                        .onChange(of: openaiKey) { _, key in Keychain.write(account: "openai", value: key.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    Text(tr("科研模式通过函数调用使用 arXiv 与 Semantic Scholar 检索；模型需支持 tools。",
                            "Research mode searches arXiv and Semantic Scholar via function calling; the model must support tools."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                HStack {
                    Button(testing ? tr("测试中…", "Testing…") : tr("测试连接", "Test connection")) { test() }
                        .disabled(testing)
                    Text(testResult).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
                Text(tr("API key 保存在 macOS 钥匙串中。", "API keys are stored in the macOS Keychain."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// The organization's Claude API spending (Admin API) and the balance estimated from the one entered here.
    private var claudeCostSection: some View {
        Section {
            SecureField(tr("Admin API key（sk-ant-admin…，可选）", "Admin API key (sk-ant-admin…, optional)"), text: $adminKey)
                .onChange(of: adminKey) { _, key in
                    Keychain.write(account: "anthropic-admin", value: key.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            HStack {
                TextField(tr("Console 中显示的当前余额（美元）", "Current balance shown in the Console (USD)"), text: $creditInput)
                Button(tr("记下", "Save")) {
                    guard let value = Double(creditInput.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "$", with: "")) else { return }
                    costResult = tr("查询中…", "Checking…")
                    claudeCost.setBalance(value) { costResult = $0 }
                    creditInput = ""
                }
                .disabled(adminKey.isEmpty || Double(creditInput.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "$", with: "")) == nil)
                Link(tr("打开结算页", "Open billing"), destination: URL(string: ClaudeCost.consoleURL)!)
            }
            if !adminKey.isEmpty {
                HStack {
                    Text(claudeCost.lines.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Spacer()
                    Button(tr("刷新", "Refresh")) {
                        costResult = tr("查询中…", "Checking…")
                        claudeCost.refresh { result in
                            if case .failure(let error) = result { costResult = error.localizedDescription } else { costResult = "" }
                        }
                    }
                }
                if settings.claudeCreditBase > 0 {
                    Text(tr("余额起点：", "Balance entered: ") + String(format: "$%.2f", settings.claudeCreditBase) + " · "
                         + timeStamp(Date(timeIntervalSince1970: settings.claudeCreditSince)))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            if !costResult.isEmpty {
                Text(costResult).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        } header: {
            Text(tr("Claude API 花费", "Claude API spending"))
        } footer: {
            Text(tr("Admin API key 由组织账户的管理员在 Claude Console 的 Settings → Admin keys 中创建（个人账户无法创建），只用于查询花费（cost_report：按 UTC 日统计，约 5 分钟延迟），不用于对话。剩余余额没有查询接口：在结算页看到余额后填入并点“记下”，桌宠从中扣除此后的花费作为估算（同一组织其它用途的花费也会扣除）。",
                    "An Admin API key is created by an organization admin under Settings → Admin keys in the Claude Console (individual accounts cannot create one); it is used only to read spending (cost_report: by UTC day, about 5 minutes behind), never for chats. There is no API for the remaining balance: enter the balance shown on the billing page and press Save, and the pet deducts later spending as an estimate (spending of the organization elsewhere counts too)."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func test() {
        testing = true
        testResult = ""
        Task {
            let result: String
            do {
                let provider = try Providers.current(settings)
                let turn = try await provider.send(LLMRequest(system: "Reply with the single word: OK",
                                                              messages: [provider.userMessage("ping")], effort: "low", maxTokens: 1000))
                result = "✓ " + (turn.model ?? "") + " · " + turn.text.prefix(40)
            } catch {
                result = "✗ " + error.localizedDescription
            }
            await MainActor.run { testResult = result; testing = false }
        }
    }

    // MARK: Reminders

    private var reminders: some View {
        Form {
            Section {
                Text(tr("桌宠不再说固定的定时提醒。下面填写的是你的作息：到了这些时刻，桌宠会结合当时的情境与记忆想一想，由它判断要不要、怎样关心你（需开启“念头式搭话”）。你亲口交代的提醒（如“30 分钟后提醒我开会”）和日历日程作为最重要的记忆保存，到点一定提醒，并发系统通知。",
                        "The pet no longer says fixed timed reminders. Below is your day: at these moments the pet thinks about it with the situation and its memories, and decides whether and how to care (with inner thoughts on). Reminders you ask for (\"remind me in 30 minutes\") and calendar events are kept as the most important memories and always given when due, with a notification."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(tr("吃饭", "Meals")) {
                Toggle(tr("饭点时让桌宠想一想", "Think of me at meal times"), isOn: $settings.reminders.mealsEnabled)
                TextField(tr("时间（逗号分隔，如 08:00, 12:00, 18:30）", "Times (comma separated, e.g. 08:00, 12:00, 18:30)"), text: $mealTimes)
                    .onSubmit(saveMeals)
                    .onChange(of: mealTimes) { saveMeals() }
            }
            Section(tr("工作", "Work")) {
                Toggle(tr("上下班时让桌宠想一想", "Think of me at the start and end of work"), isOn: $settings.reminders.workEnabled)
                HStack {
                    TextField(tr("上班", "Start"), text: $settings.reminders.workStart)
                    TextField(tr("下班", "End"), text: $settings.reminders.workEnd)
                }
                Toggle(tr("仅工作日", "Weekdays only"), isOn: $settings.reminders.weekdaysOnly)
                Stepper(value: $settings.reminders.sedentaryMinutes, in: 15...180, step: 5) {
                    Toggle(tr("连续坐 \(settings.reminders.sedentaryMinutes) 分钟后让桌宠想一想", "Think of me after \(settings.reminders.sedentaryMinutes) min of sitting"),
                           isOn: $settings.reminders.sedentaryEnabled)
                }
                Stepper(value: $settings.reminders.waterMinutes, in: 20...240, step: 10) {
                    Toggle(tr("每 \(settings.reminders.waterMinutes) 分钟想一想喝水的事", "Think of water every \(settings.reminders.waterMinutes) min"),
                           isOn: $settings.reminders.waterEnabled)
                }
            }
            Section {
                Stepper(value: $settings.chatterMinutes, in: 0...240, step: 5) {
                    Text(settings.chatterMinutes == 0 ? tr("主动闲聊：关闭", "Spontaneous remarks: off")
                         : settings.innerThoughts ? tr("主动闲聊：每 \(settings.chatterMinutes) 分钟想一想", "Spontaneous remarks: think every \(settings.chatterMinutes) min")
                         : tr("主动闲聊：每 \(settings.chatterMinutes) 分钟", "Spontaneous remarks every \(settings.chatterMinutes) min"))
                }
                Toggle(tr("念头式搭话：先产生念头，足够想说、时机合适时才开口", "Inner thoughts: speak only when a thought is strong enough"), isOn: $settings.innerThoughts)
                if settings.innerThoughts {
                    Picker(tr("健谈程度", "Talkativeness"), selection: $settings.talkativeness) {
                        ForEach(Talkativeness.allCases) { Text($0.title).tag($0) }
                    }
                } else {
                    Text(tr("关闭后桌宠不会主动开口（提醒与日程仍会到点直接念出）。", "Off: the pet does not speak of its own accord (reminders and events are still read out when due)."))
                        .font(.caption).foregroundStyle(.orange)
                }
                Toggle(tr("跟进之前聊过的事（如考试、组会结束后问问结果）", "Follow up on things mentioned before (e.g. ask how an exam went)"), isOn: $settings.followUps)
            } header: {
                Text(tr("闲聊", "Small talk"))
            } footer: {
                Text(tr("桌宠的每一句主动的话都来自念头：定时“想一想”，以及启动、你回来、摸它、放音乐、作息时刻、天气或余额变化、它跳上桌面图标等时刻，都会调用一次模型。它根据时间、你是否在忙、连续用电脑多久、最近的对话与记忆产生几个念头并评估想说的程度，只有超过开口阈值时才说出来，听音乐时也由它决定要不要跟着摇；你连续不回应时会更少开口。跟进在事情结束后、你在电脑前时进行（8:00–23:00）；提醒与日程不受此限。最近的念头可在“记忆库”中查看。",
                        "Every word the pet says of its own accord comes from a thought: every few minutes, and when it starts, you come back, pat it, play music, at the moments of your day, on weather or balance changes and when it jumps onto a desktop icon, the model is called once. From the time, whether you are busy, how long you have been at the computer, recent chats and memories it forms a few thoughts, rates how much it wants to say each, and speaks only above the threshold; with music it also decides whether to sway. It speaks less when remarks go unanswered. Follow-ups come after the event while you are at the computer (8:00–23:00); reminders and events are not bound by this. Recent thoughts are listed under Memory."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle(tr("观察屏幕：定时截屏，让桌宠知道你在做什么", "Watch the screen: let the pet know what you are doing"), isOn: $settings.screenAwareness)
                    .onChange(of: settings.screenAwareness) { _, on in
                        if on && !ScreenWatcher.permitted { ScreenWatcher.requestPermission() }
                        screenPermitted = ScreenWatcher.permitted
                    }
                Picker(tr("间隔", "Interval"), selection: $settings.screenMinutes) {
                    ForEach([5, 10, 20, 30, 60], id: \.self) { Text(tr("每 \($0) 分钟", "Every \($0) min")).tag($0) }
                }
                .disabled(!settings.screenAwareness)
                Picker(tr("识图服务", "Service for screenshots"), selection: $settings.screenProvider) {
                    Text(tr("与对话相同（\(settings.provider.title)）", "Same as the chat (\(settings.provider.title))")).tag("")
                    Text("Claude（\(settings.anthropicModel)）").tag(ProviderKind.anthropic.rawValue)
                    Text(tr("OpenAI 兼容接口（\(settings.openaiModel)）", "OpenAI-compatible (\(settings.openaiModel))")).tag(ProviderKind.openai.rawValue)
                }
                .disabled(!settings.screenAwareness)
                if settings.screenAwareness && !Providers.configured(settings, kind: settings.screenProviderKind) {
                    Text(tr("所选的识图服务还没有填写 API key，请在“模型”页填写。", "The service chosen for screenshots has no API key yet; enter it on the Model tab."))
                        .font(.caption).foregroundStyle(.orange)
                }
                TextField(tr("不截屏的应用（名称，以逗号分隔，如：微信, 招商银行）", "Apps never captured (names, comma-separated)"), text: $settings.screenExcluded)
                    .disabled(!settings.screenAwareness)
                HStack {
                    Text(screenPermitted ? tr("✓ 已获得屏幕录制权限", "✓ Screen recording allowed")
                         : tr("尚未获得屏幕录制权限", "Screen recording not allowed yet"))
                        .font(.caption).foregroundStyle(screenPermitted ? Color.secondary : Color.orange)
                    Spacer()
                    if !screenPermitted {
                        Button(tr("打开系统设置", "Open System Settings")) {
                            ScreenWatcher.requestPermission()
                            ScreenWatcher.openPrivacySettings()
                        }
                    }
                    Button(tr("现在看一眼", "Look now")) {
                        lookResult = tr("正在看…", "Looking…")
                        ScreenWatcher.shared.look { lookResult = $0 }
                        screenPermitted = ScreenWatcher.permitted
                    }
                    .disabled(!settings.screenAwareness)
                }
                if !lookResult.isEmpty {
                    Text(lookResult).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                ForEach(screen.glances.prefix(6)) { g in
                    Text(timeStamp(g.date) + " · " + g.app + " · " + g.activity)
                        .font(.system(size: 11.5)).foregroundStyle(.secondary).textSelection(.enabled)
                }
            } header: {
                Text(tr("观察屏幕", "Watching the screen"))
            } footer: {
                Text(tr("开启后，你在电脑前时桌宠每隔一段时间截取指针所在屏幕（不含桌宠自身的窗口），交给所选的模型服务用一句话概括你在做什么，用于闲聊、跟进与回答；截图不保存到磁盘，只在内存中保留最近 12 条文字描述。同一应用、同一窗口 30 分钟内不重复截屏；除上面列出的应用外，所有应用都会截屏并如实描述（密码、验证码等凭据不逐字记录）。识图服务须支持图片输入（Claude 与 DeepSeek 的 deepseek-flash 支持，deepseek-v4-pro 不支持），可与对话所用的服务不同，并需在“系统设置 → 隐私与安全性 → 录屏与系统录音”中允许 DeskPet，允许后重启桌宠生效。每次截屏调用一次模型。",
                        "When on, while you are at the computer the pet takes a screenshot of the display under the pointer (without its own windows) now and then, and the selected model service sums up in one sentence what you are doing, for small talk, follow-ups and answers. Screenshots are never saved; only the last 12 sentences are kept in memory. The same app and window are not captured again within 30 minutes; every app except those listed above is captured and described as it is (credentials such as passwords and codes are not copied). The service for screenshots must accept images (Claude and DeepSeek's deepseek-flash do; deepseek-v4-pro does not) and may differ from the chat's and DeskPet allowed under System Settings → Privacy & Security → Screen & System Audio Recording; restart the pet after allowing it. Each look calls the model once."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle(tr("日历日程提醒", "Calendar event reminders"), isOn: $settings.calendarAlerts)
                Stepper(value: $settings.calendarLeadMinutes, in: 1...120, step: settings.calendarLeadMinutes < 10 ? 1 : 5) {
                    Text(tr("提前 \(settings.calendarLeadMinutes) 分钟提醒", "Remind \(settings.calendarLeadMinutes) min before"))
                }
                .disabled(!settings.calendarAlerts)
                Toggle(tr("聊天时让角色知道今明两天的日程", "Let the character know today's and tomorrow's events in chats"), isOn: $settings.calendarInChat)
                    .disabled(!settings.calendarAlerts)
                HStack {
                    Button(tr("读取今日日程", "Read today's events")) {
                        calendarResult = ""
                        onCheckCalendar { calendarResult = $0 }
                    }
                    Text(calendarResult).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            } header: {
                Text(tr("日历", "Calendar"))
            } footer: {
                Text(tr("读取“日历”App 中的所有日程（包括已同步的 iCloud、Google、Exchange 账户），不修改日历。每天第一次在电脑前时播报当天日程，带时间的日程在开始前提醒；已取消或已拒绝的邀请不提醒。开启“聊天时……”后，日程标题、时间与地点会随对话发给所选的模型服务。",
                        "Reads every event in the Calendar app (including synced iCloud, Google and Exchange accounts) and never changes the calendar. The day's events are announced the first time you are at the Mac each day, and timed events shortly before they start; cancelled or declined invitations are skipped. With the chat option on, event titles, times and places are sent to the chosen model service along with your messages."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button(tr("测试全部提醒", "Test all reminders"), action: onTestReminders)
            }
            Section {
                Toggle(tr("天气变化提醒", "Weather change alerts"), isOn: $settings.weatherAlerts)
                HStack {
                    Button(tr("立即检查一次", "Check now")) { weatherResult = ""; onCheckWeather { weatherResult = $0 } }
                    Text(weatherResult).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Toggle(tr("DeepSeek 余额不足提醒（低于 ¥10 / $1.50）", "DeepSeek low-balance alert (below ¥10 / $1.50)"), isOn: $settings.deepseekBalanceAlerts)
                Toggle(tr("Claude 额度提醒", "Claude limit alerts"), isOn: $settings.claudeUsageAlerts)
                Text(tr("读取 Claude Usage Widget 的数据：5 小时额度或每周额度用到 70%、90% 时提醒，5 小时额度恢复后告知。",
                        "Uses the data of the Claude Usage Widget: alerts at 70 % and 90 % of the 5-hour or weekly limit, and when the 5-hour limit is back."))
                    .font(.caption).foregroundStyle(.secondary)
            } footer: {
                Text(tr("每 20 分钟检查一次“主人信息”中所在城市的预报：未来 3 小时可能下雨或下雪、未来 6 小时有雷暴、大雨、大雪或大风、傍晚时明天明显降温或升温或有雨时提醒；同类提醒有冷却时间。",
                        "Every 20 minutes the forecast for your city is checked: rain or snow within 3 hours; thunderstorms, heavy rain or snow, or strong wind within 6 hours; and in the evening a much colder, warmer or rainy tomorrow. Each kind of alert has a cool-down."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func saveMeals() {
        let times = mealTimes.split(whereSeparator: { $0 == "," || $0 == "，" || $0 == " " })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { ReminderRules.date($0, on: Date(), .current) != nil }
        settings.reminders.mealTimes = times
    }
}
