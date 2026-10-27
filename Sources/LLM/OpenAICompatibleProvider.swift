import Foundation

/// Any service implementing the OpenAI Chat Completions API (OpenAI, DeepSeek, Qwen/DashScope,
/// Moonshot, Ollama, LM Studio, …), always streaming.
struct OpenAICompatibleProvider: LLMProvider {
    let apiKey: String
    let baseURL: String
    let model: String

    var kind: ProviderKind { .openai }

    func userMessage(_ text: String) -> JSON {
        ["role": "user", "content": .string(text)]
    }

    func assistantTextMessage(_ text: String) -> JSON {
        ["role": "assistant", "content": .string(text)]
    }

    func imageMessage(_ text: String, jpeg: Data) -> JSON {
        ["role": "user", "content": [
            ["type": "text", "text": .string(text)],
            ["type": "image_url", "image_url": ["url": .string("data:image/jpeg;base64," + jpeg.base64EncodedString())]],
        ]]
    }

    func toolResultMessages(_ results: [ToolResult]) -> [JSON] {
        results.map { ["role": "tool", "tool_call_id": .string($0.id), "content": .string($0.content)] }
    }

    var endpoint: URL? {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        if base.hasSuffix("/chat/completions") { return URL(string: base) }
        return URL(string: base + "/chat/completions")
    }

    func body(for request: LLMRequest, jsonMode: Bool) -> JSON {
        var body: [String: JSON] = [
            "model": .string(model),
            "stream": true,
            "messages": .array([["role": "system", "content": .string(request.system)]] + request.messages),
        ]
        // Models without tool support reject any tool declaration, so tools are omitted when they are
        // disabled and the history contains no tool calls.
        let historyHasTools = request.messages.contains { $0["role"]?.string == "tool" || $0["tool_calls"] != nil }
        if !request.tools.isEmpty && (!request.toolChoiceNone || historyHasTools) {
            body["tools"] = .array(request.tools.map {
                ["type": "function", "function": ["name": .string($0.name), "description": .string($0.description), "parameters": $0.schema]]
            })
            if request.toolChoiceNone { body["tool_choice"] = "none" }
        }
        if jsonMode { body["response_format"] = ["type": "json_object"] }
        if request.noThinking && sendsThinkingSwitch { body["thinking"] = ["type": "disabled"] }
        return .object(body)
    }

    /// DeepSeek's API takes a `thinking` switch; other compatible servers may reject unknown fields.
    var sendsThinkingSwitch: Bool { URL(string: baseURL)?.host?.hasSuffix("deepseek.com") == true }

    func send(_ request: LLMRequest, onEvent: @escaping (LLMStreamEvent) -> Void) async throws -> LLMTurn {
        do {
            return try await send(request, jsonMode: request.jsonSchema != nil, onEvent: onEvent)
        } catch LLMError.http(let status, let body) where status == 400 && request.jsonSchema != nil
                    && body.localizedCaseInsensitiveContains("response_format") {
            // Some compatible servers reject JSON mode; the prompt still asks for JSON and the parser is tolerant.
            return try await send(request, jsonMode: false, onEvent: onEvent)
        } catch LLMError.http(let status, let body) where status == 400 && request.noThinking
                    && body.localizedCaseInsensitiveContains("thinking") {
            // A model that does not know the switch: ask again without it.
            var plain = request
            plain.noThinking = false
            return try await send(plain, jsonMode: plain.jsonSchema != nil, onEvent: onEvent)
        }
    }

    private func send(_ request: LLMRequest, jsonMode: Bool, onEvent: @escaping (LLMStreamEvent) -> Void) async throws -> LLMTurn {
        guard let endpoint else { throw LLMError.badResponse("Base URL") }
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 600
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        if !apiKey.isEmpty { urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization") }
        urlRequest.httpBody = body(for: request, jsonMode: jsonMode).data()

        var accumulator = OpenAIStreamAccumulator()
        for try await event in URLSession.shared.sseEvents(for: urlRequest) {
            if event.data == "[DONE]" { break }
            for output in try accumulator.consume(event.data) { onEvent(output) }
        }
        let turn = accumulator.finish()
        for call in turn.toolCalls {
            onEvent(.status(AnthropicStreamAccumulator.statusText(tool: call.name, query: call.input["query"]?.string ?? "")))
        }
        return turn
    }
}

struct OpenAIStreamAccumulator {
    /// Everything the model wrote as content.
    private var raw = ""
    /// The content without tool-call markup (what is shown and kept).
    private var visible = ""
    /// Held-back text that may be the start of markup.
    private var pending = ""
    private var inMarkup = false
    private var calls: [Int: (id: String, name: String, arguments: String)] = [:]
    private var finishReason: String?
    private var model: String?

    /// Some models (DeepSeek) occasionally write their native tool-call syntax into the content instead of
    /// `tool_calls`, e.g. `<｜｜DSML｜｜ invoke name="search_news">…`. Such markup is hidden and parsed.
    static let markupStarts = ["<｜｜DSML", "<｜DSML", "<｜tool"]

    mutating func consume(_ data: String) throws -> [LLMStreamEvent] {
        guard let json = try? JSON.parse(data) else { return [] }
        if let error = json["error"] {
            throw LLMError.api(error["message"]?.string ?? error.compactString)
        }
        model = json["model"]?.string ?? model
        guard let choice = json["choices"]?[0] else { return [] }
        if let reason = choice["finish_reason"]?.string { finishReason = reason }
        let delta = choice["delta"]
        var out: [LLMStreamEvent] = []
        if let piece = delta?["content"]?.string, !piece.isEmpty {
            let shown = filter(piece)
            if !shown.isEmpty { out.append(.text(shown)) }
        }
        for call in delta?["tool_calls"]?.array ?? [] {
            let index = call["index"]?.int ?? 0
            var entry = calls[index] ?? (id: "", name: "", arguments: "")
            if let id = call["id"]?.string, !id.isEmpty { entry.id = id }
            if let name = call["function"]?["name"]?.string, !name.isEmpty { entry.name += name }
            entry.arguments += call["function"]?["arguments"]?.string ?? ""
            calls[index] = entry
        }
        return out
    }

    /// Returns the part of `piece` that can be shown; markup and anything after it is withheld.
    private mutating func filter(_ piece: String) -> String {
        raw += piece
        guard !inMarkup else { return "" }
        pending += piece
        var out = ""
        while let r = pending.range(of: "<｜") {
            out += pending[..<r.lowerBound]
            let tail = String(pending[r.lowerBound...])
            if Self.markupStarts.contains(where: { tail.hasPrefix($0) }) {
                inMarkup = true
                pending = ""
                visible += out
                return out
            }
            if Self.markupStarts.contains(where: { $0.hasPrefix(tail) }) {
                pending = tail  // may still turn into markup
                visible += out
                return out
            }
            out += "<｜"
            pending = String(tail.dropFirst(2))
        }
        out += pending
        pending = ""
        visible += out
        return out
    }

    /// Tool calls written as DSML markup: `invoke name="…"` with `parameter name="…" string="true|false"`.
    static func markupCalls(in raw: String) -> [(name: String, input: JSON)] {
        let invoke = try! NSRegularExpression(pattern: #"invoke\s+name="([^"]+)"\s*>(.*?)</[^>]*?invoke>"#,
                                              options: [.dotMatchesLineSeparators])
        let parameter = try! NSRegularExpression(pattern: #"parameter\s+name="([^"]+)"(?:\s+string="(true|false)")?\s*>(.*?)</[^>]*?parameter>"#,
                                                 options: [.dotMatchesLineSeparators])
        let ns = raw as NSString
        return invoke.matches(in: raw, range: NSRange(location: 0, length: ns.length)).map { m in
            let name = ns.substring(with: m.range(at: 1))
            let body = ns.substring(with: m.range(at: 2))
            let bns = body as NSString
            var input: [String: JSON] = [:]
            for p in parameter.matches(in: body, range: NSRange(location: 0, length: bns.length)) {
                let key = bns.substring(with: p.range(at: 1))
                let isString = p.range(at: 2).location != NSNotFound && bns.substring(with: p.range(at: 2)) == "true"
                let value = bns.substring(with: p.range(at: 3)).trimmingCharacters(in: .whitespacesAndNewlines)
                // JSON arrays/objects are parsed even when marked as strings (e.g. a list of symbols).
                if value.hasPrefix("[") || value.hasPrefix("{") || !isString, let parsed = try? JSON.parse(value) {
                    input[key] = parsed
                } else {
                    input[key] = .string(value)
                }
            }
            return (name, .object(input))
        }
    }

    func finish() -> LLMTurn {
        var shown = visible
        if !inMarkup { shown += pending }
        shown = shown.trimmingCharacters(in: .whitespacesAndNewlines)

        let ordered = calls.keys.sorted().compactMap { calls[$0] }
        var toolCalls = ordered.enumerated().map { i, c in
            ToolCall(id: c.id.isEmpty ? "call_\(i)" : c.id, name: c.name,
                     input: (try? JSON.parse(c.arguments.isEmpty ? "{}" : c.arguments)) ?? .object([:]))
        }
        var arguments = ordered.map { $0.arguments.isEmpty ? "{}" : $0.arguments }
        if toolCalls.isEmpty && inMarkup {
            for (i, call) in Self.markupCalls(in: raw).enumerated() {
                toolCalls.append(ToolCall(id: "markup_\(i)", name: call.name, input: call.input))
                arguments.append(call.input.compactString)
            }
        }

        var message: [String: JSON] = ["role": "assistant", "content": shown.isEmpty ? .null : .string(shown)]
        if !toolCalls.isEmpty {
            message["tool_calls"] = .array(zip(toolCalls, arguments).map { call, args in
                ["id": .string(call.id), "type": "function",
                 "function": ["name": .string(call.name), "arguments": .string(args)]]
            })
        }
        let reason: StopReason
        switch finishReason {
        case "tool_calls", "function_call": reason = .toolUse
        case "length": reason = .maxTokens
        case "stop", nil: reason = toolCalls.isEmpty ? .end : .toolUse
        case let other?: reason = toolCalls.isEmpty ? .other(other) : .toolUse
        }
        return LLMTurn(text: shown, toolCalls: toolCalls, stopReason: reason,
                       assistantMessage: .object(message), citations: [], model: model)
    }
}
