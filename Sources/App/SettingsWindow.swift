import AppKit
import SwiftUI

final class SettingsWindowController {
    private var window: NSWindow?
    var onModelChange: (() -> Void)?
    var onTestReminders: (() -> Void)?
    var onRunDailyTasks: (() -> Void)?
    var onCheckWeather: ((@escaping (String) -> Void) -> Void)?
    var onPreviewMeow: (() -> Void)?
    var onInstallSaver: (() -> String)?

    func show(tab: SettingsView.Tab = .general) {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(
                initialTab: tab,
                onModelChange: { [weak self] in self?.onModelChange?() },
                onTestReminders: { [weak self] in self?.onTestReminders?() },
                onRunDailyTasks: { [weak self] in self?.onRunDailyTasks?() },
                onCheckWeather: { [weak self] report in self?.onCheckWeather?(report) },
                onPreviewMeow: { [weak self] in self?.onPreviewMeow?() },
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
    var onCheckWeather: (@escaping (String) -> Void) -> Void
    var onPreviewMeow: () -> Void
    var onInstallSaver: () -> String
    @State private var saverResult = ""

    @ObservedObject private var memory = MemoryStore.shared
    @State private var newMemory = ""
    @State private var confirmClear = false
    @State private var weatherResult = ""

    @State private var anthropicKey = Keychain.hasValue(account: "anthropic") ? (Keychain.read(account: "anthropic") ?? "") : ""
    @State private var openaiKey = Keychain.hasValue(account: "openai") ? (Keychain.read(account: "openai") ?? "") : ""
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
            } footer: {
                Text(tr("记忆保存在本机，并作为背景随每次请求发送给所选的模型服务。对桌宠说“忘掉……”也可删除相关记忆。",
                        "Memories stay on this Mac and are sent as background with each request to the selected model provider. Saying “forget …” to the pet removes matching memories."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(tr("共 \(memory.items.count) 条", "\(memory.items.count) memories")) {
                if memory.items.isEmpty {
                    Text(tr("还没有记忆。", "No memories yet.")).foregroundStyle(.secondary)
                }
                ForEach(memory.items) { m in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.text).font(.system(size: 12.5)).textSelection(.enabled)
                            Text(ReminderRules.dayStamp(m.created, .current) + (m.source == "manual" ? tr(" · 手动添加", " · added manually") : ""))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { memory.remove(m.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .help(tr("删除", "Delete"))
                    }
                }
                if !memory.items.isEmpty {
                    Button(tr("清空全部记忆…", "Clear all memories…"), role: .destructive) { confirmClear = true }
                        .confirmationDialog(tr("确定清空全部 \(memory.items.count) 条记忆？此操作无法撤销。", "Clear all \(memory.items.count) memories? This cannot be undone."),
                                            isPresented: $confirmClear) {
                            Button(tr("清空", "Clear"), role: .destructive) { memory.removeAll() }
                        }
                }
            }
        }
        .formStyle(.grouped)
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

            if settings.provider == .anthropic {
                Section("Claude") {
                    SecureField("API key", text: $anthropicKey)
                        .onChange(of: anthropicKey) { _, key in Keychain.write(account: "anthropic", value: key.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    TextField(tr("模型", "Model"), text: $settings.anthropicModel)
                    Toggle(tr("拒答时由服务端自动回退到其它模型", "Server-side fallback on refusals"), isOn: $settings.serverFallback)
                    Text(tr("默认模型 claude-opus-5-5；科研模式使用服务端 web_search 工具检索网页，另提供 arXiv 与 Semantic Scholar 检索。",
                            "Default model claude-opus-5-5. Research mode uses the server-side web_search tool plus arXiv and Semantic Scholar search."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Section(tr("OpenAI 兼容接口", "OpenAI-compatible")) {
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
            Section(tr("吃饭", "Meals")) {
                Toggle(tr("提醒吃饭", "Meal reminders"), isOn: $settings.reminders.mealsEnabled)
                TextField(tr("时间（逗号分隔，如 08:00, 12:00, 18:30）", "Times (comma separated, e.g. 08:00, 12:00, 18:30)"), text: $mealTimes)
                    .onSubmit(saveMeals)
                    .onChange(of: mealTimes) { saveMeals() }
            }
            Section(tr("工作", "Work")) {
                Toggle(tr("上下班提醒", "Start/end of work"), isOn: $settings.reminders.workEnabled)
                HStack {
                    TextField(tr("上班", "Start"), text: $settings.reminders.workStart)
                    TextField(tr("下班", "End"), text: $settings.reminders.workEnd)
                }
                Toggle(tr("仅工作日", "Weekdays only"), isOn: $settings.reminders.weekdaysOnly)
                Stepper(value: $settings.reminders.sedentaryMinutes, in: 15...180, step: 5) {
                    Toggle(tr("久坐提醒：每 \(settings.reminders.sedentaryMinutes) 分钟", "Stand-up reminder every \(settings.reminders.sedentaryMinutes) min"),
                           isOn: $settings.reminders.sedentaryEnabled)
                }
                Stepper(value: $settings.reminders.waterMinutes, in: 20...240, step: 10) {
                    Toggle(tr("喝水提醒：每 \(settings.reminders.waterMinutes) 分钟", "Water reminder every \(settings.reminders.waterMinutes) min"),
                           isOn: $settings.reminders.waterEnabled)
                }
            }
            Section(tr("闲聊", "Small talk")) {
                Stepper(value: $settings.chatterMinutes, in: 0...240, step: 5) {
                    Text(settings.chatterMinutes == 0 ? tr("主动闲聊：关闭", "Spontaneous remarks: off")
                         : tr("主动闲聊：每 \(settings.chatterMinutes) 分钟", "Spontaneous remarks every \(settings.chatterMinutes) min"))
                }
                Stepper(value: $settings.chatterLLMEvery, in: 0...10) {
                    Text(settings.chatterLLMEvery == 0 ? tr("闲聊内容：仅本地语料", "Remarks: local phrases only")
                         : tr("每 \(settings.chatterLLMEvery) 次闲聊由模型生成 1 次", "1 of every \(settings.chatterLLMEvery) remarks written by the model"))
                }
                Toggle(tr("由模型以角色口吻改写提醒", "Let the model phrase reminders in character"), isOn: $settings.aiReminderWording)
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
