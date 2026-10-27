import Foundation

/// Claude through the Messages API over raw HTTP (Swift has no official SDK), always streaming.
struct AnthropicProvider: LLMProvider {
    let apiKey: String
    let model: String
    /// Server-side refusal fallback (`fallbacks: "default"`), sent only to models that accept it.
    let serverFallback: Bool
    var endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    var kind: ProviderKind { .anthropic }

    private static let fallbackBeta = "server-side-fallback-2026-07-01"

    /// Models that accept `fallbacks: "default"` on the Claude API.
    private var acceptsFallback: Bool {
        ["claude-opus-5-5", "claude-opus-5", "claude-fable-5-1", "claude-fable-5", "claude-sonnet-5-5"]
            .contains(where: { model == $0 })
    }

    func userMessage(_ text: String) -> JSON {
        ["role": "user", "content": .string(text)]
    }

    func assistantTextMessage(_ text: String) -> JSON {
        ["role": "assistant", "content": [["type": "text", "text": .string(text)]]]
    }

    func imageMessage(_ text: String, jpeg: Data) -> JSON {
        ["role": "user", "content": [
            ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": .string(jpeg.base64EncodedString())]],
            ["type": "text", "text": .string(text)],
        ]]
    }

    func toolResultMessages(_ results: [ToolResult]) -> [JSON] {
        // All results of one turn go back in a single user message.
        let blocks: [JSON] = results.map {
            ["type": "tool_result", "tool_use_id": .string($0.id), "content": .string($0.content), "is_error": .bool($0.isError)]
        }
        return [["role": "user", "content": .array(blocks)]]
    }

    func body(for request: LLMRequest) -> JSON {
        var body: [String: JSON] = [
            "model": .string(model),
            "max_tokens": .number(Double(request.maxTokens)),
            "stream": true,
            // The system prompt is static per mode; volatile context (time) goes in the user turn.
            "system": [["type": "text", "text": .string(request.system)]],
            "messages": .array(request.messages),
            // Automatic prompt caching of the longest stable prefix.
            "cache_control": ["type": "ephemeral"],
        ]
        var outputConfig: [String: JSON] = [:]
        if let effort = request.effort { outputConfig["effort"] = .string(effort) }
        if let schema = request.jsonSchema { outputConfig["format"] = ["type": "json_schema", "schema": schema] }
        if !outputConfig.isEmpty { body["output_config"] = .object(outputConfig) }

        var tools: [JSON] = request.tools.map {
            ["name": .string($0.name), "description": .string($0.description), "input_schema": $0.schema]
        }
        if request.webSearch {
            tools.append(["type": "web_search_20260209", "name": "web_search", "max_uses": 5])
        }
        if !tools.isEmpty {
            body["tools"] = .array(tools)
            // Forced tool choice ("any"/"tool") is rejected by current models; only "auto" and "none" are used.
            if request.toolChoiceNone { body["tool_choice"] = ["type": "none"] }
        }
        if serverFallback && acceptsFallback { body["fallbacks"] = "default" }
        return .object(body)
    }

    func send(_ request: LLMRequest, onEvent: @escaping (LLMStreamEvent) -> Void) async throws -> LLMTurn {
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 600
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if serverFallback && acceptsFallback {
            urlRequest.setValue(Self.fallbackBeta, forHTTPHeaderField: "anthropic-beta")
        }
        urlRequest.httpBody = body(for: request).data()

        var accumulator = AnthropicStreamAccumulator()
        for try await event in URLSession.shared.sseEvents(for: urlRequest) {
            for output in try accumulator.consume(event) { onEvent(output) }
        }
        return try accumulator.finish()
    }
}

/// Rebuilds the response message from Messages API stream events.
struct AnthropicStreamAccumulator {
    private var blocks: [Int: [String: JSON]] = [:]
    private var partialJSON: [Int: String] = [:]
    private var stopReason: String?
    private var stopCategory: String?
    private var model: String?

    mutating func consume(_ event: SSEEvent) throws -> [LLMStreamEvent] {
        guard let json = try? JSON.parse(event.data), let type = json["type"]?.string else { return [] }
        var out: [LLMStreamEvent] = []
        switch type {
        case "message_start":
            model = json["message"]?["model"]?.string ?? model
        case "content_block_start":
            guard let index = json["index"]?.int, let block = json["content_block"]?.object else { break }
            blocks[index] = block
            if block["type"]?.string == "text", let text = block["text"]?.string, !text.isEmpty {
                out.append(.text(text))
            }
            if block["type"]?.string == "web_search_tool_result" {
                // Errors arrive as an object instead of a result list, inside an HTTP 200 response.
                if let code = block["content"]?["error_code"]?.string {
                    out.append(.status(tr("检索失败：", "Search failed: ") + code))
                } else {
                    out.append(.status(tr("已获得检索结果", "Search results received")))
                }
            }
        case "content_block_delta":
            guard let index = json["index"]?.int, let delta = json["delta"] else { break }
            switch delta["type"]?.string {
            case "text_delta":
                let piece = delta["text"]?.string ?? ""
                let previous = blocks[index]?["text"]?.string ?? ""
                blocks[index]?["text"] = .string(previous + piece)
                out.append(.text(piece))
            case "input_json_delta":
                partialJSON[index, default: ""] += delta["partial_json"]?.string ?? ""
            case "thinking_delta":
                let previous = blocks[index]?["thinking"]?.string ?? ""
                blocks[index]?["thinking"] = .string(previous + (delta["thinking"]?.string ?? ""))
            case "signature_delta":
                blocks[index]?["signature"] = .string(delta["signature"]?.string ?? "")
            case "citations_delta":
                if let citation = delta["citation"] {
                    var list = blocks[index]?["citations"]?.array ?? []
                    list.append(citation)
                    blocks[index]?["citations"] = .array(list)
                }
            default:
                break
            }
        case "content_block_stop":
            guard let index = json["index"]?.int, var block = blocks[index] else { break }
            if let raw = partialJSON.removeValue(forKey: index) {
                block["input"] = raw.isEmpty ? .object([:]) : ((try? JSON.parse(raw)) ?? .object([:]))
            }
            blocks[index] = block
            if block["type"]?.string == "server_tool_use" || block["type"]?.string == "tool_use" {
                let query = block["input"]?["query"]?.string ?? ""
                let name = block["name"]?.string ?? ""
                out.append(.status(Self.statusText(tool: name, query: query)))
            }
        case "message_delta":
            if let reason = json["delta"]?["stop_reason"]?.string { stopReason = reason }
            if let category = json["delta"]?["stop_details"]?["category"]?.string { stopCategory = category }
        case "error":
            let message = json["error"]?["message"]?.string ?? event.data
            throw LLMError.api(message)
        default:
            break  // ping, message_stop
        }
        return out
    }

    static func statusText(tool: String, query: String) -> String {
        switch tool {
        case "web_search": return tr("联网检索：", "Web search: ") + query
        case "search_arxiv": return tr("检索 arXiv：", "Searching arXiv: ") + query
        case "search_semantic_scholar": return tr("检索 Semantic Scholar：", "Searching Semantic Scholar: ") + query
        default: return tr("调用工具：", "Tool: ") + tool
        }
    }

    func finish() throws -> LLMTurn {
        if stopReason == "refusal" {
            // Partial output of a declined response is discarded.
            throw LLMError.refusal(stopCategory)
        }
        let content = Self.sanitizedForReplay(blocks.keys.sorted().compactMap { blocks[$0] })
        var text = ""
        var calls: [ToolCall] = []
        var citations: [Citation] = []
        for block in content {
            switch block["type"]?.string {
            case "text":
                text += block["text"]?.string ?? ""
                for c in block["citations"]?.array ?? [] {
                    if let url = c["url"]?.string {
                        let citation = Citation(title: c["title"]?.string ?? url, url: url)
                        if !citations.contains(citation) { citations.append(citation) }
                    }
                }
            case "tool_use":
                if let id = block["id"]?.string, let name = block["name"]?.string {
                    calls.append(ToolCall(id: id, name: name, input: block["input"] ?? .object([:])))
                }
            default:
                break
            }
        }
        let reason: StopReason
        switch stopReason {
        case "end_turn", "stop_sequence", nil: reason = .end
        case "tool_use": reason = .toolUse
        case "pause_turn": reason = .pauseTurn
        case "max_tokens", "model_context_window_exceeded": reason = .maxTokens
        case let other?: reason = .other(other)
        }
        return LLMTurn(text: text, toolCalls: calls, stopReason: reason,
                       assistantMessage: ["role": "assistant", "content": .array(content.map { .object($0) })],
                       citations: citations, model: model)
    }

    /// After a mid-output server-side fallback, the blocks before the last `fallback` marker that the
    /// fallback model did not continue from (thinking, unpaired tool calls, unknown internal types)
    /// must not be echoed back; the marker itself is dropped as well.
    static func sanitizedForReplay(_ content: [[String: JSON]]) -> [[String: JSON]] {
        guard let boundary = content.lastIndex(where: { $0["type"]?.string == "fallback" }) else { return content }
        let resultIDs = Set(content.compactMap { $0["tool_use_id"]?.string })
        let keptTypes: Set<String> = ["text", "web_search_tool_result", "web_fetch_tool_result"]
        var result: [[String: JSON]] = []
        for (i, block) in content.enumerated() {
            let type = block["type"]?.string ?? ""
            if i == boundary { continue }
            if i > boundary { result.append(block); continue }
            if keptTypes.contains(type) { result.append(block); continue }
            if type == "server_tool_use", let id = block["id"]?.string, resultIDs.contains(id) { result.append(block) }
        }
        return result
    }
}
