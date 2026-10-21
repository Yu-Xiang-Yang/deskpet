import Foundation

/// Runs research turns (streaming, literature-search tool loop, persistence, titles) for both front ends:
/// the pet's answer bubbles in research mode and the message list window.
@MainActor
final class ResearchEngine {
    struct Events {
        /// The user message was stored; `title` is set when the conversation got its provisional title.
        var onStart: (_ conversationID: String, _ user: StoredMessage, _ assistantID: UUID) -> Void = { _, _, _ in }
        var onDelta: (_ assistantID: UUID, _ text: String) -> Void = { _, _ in }
        var onStatus: (_ assistantID: UUID, _ status: String) -> Void = { _, _ in }
        var onFinish: (_ assistantID: UUID, _ text: String, _ citations: [Citation]) -> Void = { _, _, _ in }
        var onFail: (_ assistantID: UUID, _ message: String) -> Void = { _, _ in }
        var onEnd: () -> Void = {}
    }

    private let settings = AppSettings.shared
    private let store = ConversationStore.shared
    private var task: Task<Void, Never>?
    private(set) var runningID: String?

    var isBusy: Bool { task != nil }

    /// Whether the literature search tools may be called (the toggle of the message list).
    var webSearch: Bool {
        get { UserDefaults.standard.object(forKey: "researchWeb") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "researchWeb") }
    }

    /// At most two rounds of tool calls; the third model call has to answer.
    private static let maxIterations = 3

    /// The research prompt plus the owner's background (stable until the profile is edited).
    var systemPrompt: String {
        let owner = settings.ownerSection + MemoryStore.shared.promptSection
        let mode = settings.researchModeName.trimmingCharacters(in: .whitespaces)
        let persona = mode.isEmpty ? "" : "你是桌面助手「\(settings.petName)」的 \(mode) 模式，即其最高运算状态：语气冷静、克制、精确，"
            + "不寒暄、不使用颜文字，以结论、证据与数据说话。\n"
        return persona + Self.basePrompt + (owner.isEmpty ? "" : owner + "\n回答时结合主人的背景与记忆调整深度与侧重点。")
    }

    static let basePrompt = """
    你是一名严谨的科研助手，服务对象为研究人员与研究生。回答要求：
    1. 使用与用户相同的语言。回答会先显示在桌宠的对话气泡中：开头先用两三句话直接给出结论，再给出推导、证据或步骤。
    2. 区分已确立的事实、文献中的结论与推测；不确定之处明确说明，不编造文献、数据或引用。
    3. 数学公式使用 LaTeX：行内用 $...$，独立公式用 $$...$$。代码使用带语言标注的代码块。
    4. 需要文献支持或涉及近期进展时，使用检索工具（web_search、search_arxiv、search_semantic_scholar）查找，\
    并在回答末尾列出参考文献（作者、标题、年份、出处或链接）。只引用检索结果或公认经典文献中确实存在的条目。\
    新闻与时事使用 search_news，股票与指数行情使用 get_stock_quotes，阅读网页原文使用 fetch_webpage。
    5. 默认简洁：正文控制在 300–600 字，只保留关键公式与要点；用户明确要求“详细”“推导”“完整代码”等时再展开。\
    可使用小标题、列表与表格组织内容。
    6. 检索要克制：仅在确有必要时检索；需要检索时在同一轮并行发起所需的全部查询（最多 3 个），拿到结果后直接作答，\
    不要逐个反复检索。某个来源报错或被限流时改用其它来源或依据已有知识作答，并说明。
    """

    func cancel() { task?.cancel() }

    /// Starts a turn in `conversationID`, or in a new research conversation when it is nil or unknown.
    /// Returns the conversation id, or nil when another turn is still running.
    @discardableResult
    /// `forceTools` overrides the web-search toggle (daily tasks always need current data).
    func ask(_ text: String, in conversationID: String?, title fixedTitle: String? = nil, forceTools: Bool = false,
             events: Events) -> String? {
        guard task == nil else { return nil }
        var conversation = conversationID.flatMap { store.load($0) } ?? store.newResearch()
        let conversationID = conversation.id

        let isFirst = conversation.messages.isEmpty && fixedTitle == nil
        let userMessage = StoredMessage(role: .user, text: text)
        conversation.messages.append(userMessage)
        if let fixedTitle { conversation.title = fixedTitle } else if isFirst { conversation.title = String(text.prefix(24)) }
        store.save(conversation)

        let assistantID = UUID()
        runningID = conversationID
        events.onStart(conversationID, userMessage, assistantID)

        let useTools = forceTools || webSearch
        // Without tools the prompt must not ask for them, or the model may write its tool-call syntax as text.
        let system = systemPrompt + (useTools ? "" : "\n\n本轮检索工具不可用：请直接依据已有知识回答，不要输出任何工具调用或其标记；如需最新信息，说明这一点。")
        let history = conversation.messages.dropLast()
        task = Task { [weak self] in
            guard let self else { return }
            var fullText = ""
            var citations: [Citation] = []
            var wire: [JSON] = []
            var providerKind = ProviderKind.anthropic
            var model: String?
            do {
                let provider = try Providers.current(self.settings)
                providerKind = provider.kind
                let base = Self.history(Array(history), provider: provider) + [provider.userMessage(text)]
                for iteration in 0..<Self.maxIterations {
                    try Task.checkCancellation()
                    if !fullText.isEmpty && !fullText.hasSuffix("\n\n") {
                        let sep = fullText.hasSuffix("\n") ? "\n" : "\n\n"
                        fullText += sep
                        events.onDelta(assistantID, sep)
                    }
                    // The final allowed iteration may not call tools, so the turn always ends with an answer.
                    let lastRound = iteration == Self.maxIterations - 1
                    let request = LLMRequest(system: system, messages: base + wire,
                                             tools: ResearchTools.specs, webSearch: provider.kind == .anthropic,
                                             effort: "high", maxTokens: 64000, toolChoiceNone: !useTools || lastRound)
                    let turn = try await provider.send(request) { event in
                        Task { @MainActor in
                            switch event {
                            case .text(let piece): events.onDelta(assistantID, piece)
                            case .status(let status): events.onStatus(assistantID, status)
                            }
                        }
                    }
                    model = turn.model ?? model
                    wire.append(turn.assistantMessage)
                    fullText += turn.text
                    for c in turn.citations where !citations.contains(c) { citations.append(c) }

                    if turn.stopReason == .toolUse, !turn.toolCalls.isEmpty {
                        let results = await withTaskGroup(of: (Int, ToolResult).self) { group in
                            for (i, call) in turn.toolCalls.enumerated() {
                                group.addTask { (i, await ResearchTools.run(call)) }
                            }
                            var collected: [(Int, ToolResult)] = []
                            for await r in group { collected.append(r) }
                            return collected.sorted { $0.0 < $1.0 }.map(\.1)
                        }
                        wire += provider.toolResultMessages(results)
                        continue
                    }
                    if turn.stopReason == .pauseTurn { continue }  // server-side tool loop paused; resend to resume
                    if turn.stopReason == .maxTokens {
                        fullText += tr("\n\n（输出达到长度上限，已截断。）", "\n\n(Output reached the length limit.)")
                    }
                    break
                }
                if fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    fullText = tr("（未能生成回答，请稍后重试。）", "(No answer was produced; please try again.)")
                    events.onDelta(assistantID, fullText)
                }
                var c = self.store.load(conversationID) ?? conversation
                c.messages.append(StoredMessage(id: assistantID, role: .assistant, text: fullText,
                                                citations: citations.isEmpty ? nil : citations,
                                                wireProvider: providerKind.rawValue, wire: wire, model: model))
                self.store.save(c)
                events.onFinish(assistantID, fullText, citations)
                if isFirst { self.generateTitle(conversationID, question: text, answer: fullText) }
            } catch {
                let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
                var c = self.store.load(conversationID) ?? conversation
                if cancelled && !fullText.isEmpty {
                    // Keep what was received; it is replayed as plain text.
                    let text = fullText + tr("\n\n（已停止）", "\n\n(Stopped)")
                    c.messages.append(StoredMessage(id: assistantID, role: .assistant, text: text,
                                                    citations: citations.isEmpty ? nil : citations))
                    events.onFinish(assistantID, text, citations)
                } else {
                    if let i = c.messages.lastIndex(where: { $0.id == userMessage.id }) { c.messages[i].failed = true }
                    let message = cancelled ? tr("已停止。", "Stopped.") : error.localizedDescription
                    c.messages.append(StoredMessage(role: .error, text: message))
                    events.onFail(assistantID, message)
                }
                self.store.save(c)
            }
            self.task = nil
            self.runningID = nil
            events.onEnd()
        }
        return conversationID
    }

    /// Wire history for a research conversation: stored wire messages are replayed unchanged when the
    /// provider is the same (append-only history); otherwise the visible text stands in.
    static func history(_ messages: [StoredMessage], provider: LLMProvider) -> [JSON] {
        var result: [JSON] = []
        for m in messages {
            switch m.role {
            case .user where m.failed != true:
                result.append(provider.userMessage(m.raw ?? m.text))
            case .assistant:
                if m.wireProvider == provider.kind.rawValue, let wire = m.wire, !wire.isEmpty {
                    result += wire
                } else if !m.text.isEmpty {
                    result.append(provider.assistantTextMessage(m.text))
                }
            default:
                break
            }
        }
        return result
    }

    private func generateTitle(_ id: String, question: String, answer: String) {
        Task { [weak self] in
            guard let self, let provider = try? Providers.current(self.settings) else { return }
            let prompt = "为以下科研对话生成一个不超过 16 个字的标题，只输出标题本身，不加引号或标点。\n\n问题：\(question.prefix(800))\n\n回答摘要：\(answer.prefix(800))"
            guard let turn = try? await provider.send(LLMRequest(system: "你为对话生成简洁的标题。", messages: [provider.userMessage(prompt)],
                                                                 effort: "low", maxTokens: 2000)) else { return }
            let title = turn.text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”《》「」")))
            guard !title.isEmpty, title.count <= 40 else { return }
            self.store.rename(id, to: title)
        }
    }
}
