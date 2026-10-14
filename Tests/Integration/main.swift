import Foundation

// Integration test: both providers against Tests/mock_server.py over real HTTP streaming, plus the
// live arXiv and Semantic Scholar tools. Run: scripts/integration-test.sh

let base = ProcessInfo.processInfo.environment["MOCK_URL"] ?? "http://127.0.0.1:8799"
let logFile = ProcessInfo.processInfo.environment["MOCK_LOG"] ?? ""
var failures = 0
func check(_ ok: Bool, _ name: String) { print((ok ? "ok   " : "FAIL ") + name); if !ok { failures += 1 } }

func requests() -> [JSON] {
    ((try? String(contentsOfFile: logFile, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { try? JSON.parse(String($0)) }
}

/// The research tool loop as in ResearchWindowController, without UI.
func researchLoop(_ provider: LLMProvider, question: String) async throws -> (String, [Citation], [JSON], [String]) {
    var wire: [JSON] = []
    var text = ""
    var citations: [Citation] = []
    var statuses: [String] = []
    for _ in 0..<8 {
        let turn = try await provider.send(LLMRequest(system: "research", messages: [provider.userMessage(question)] + wire,
                                                      tools: ResearchTools.specs, webSearch: provider.kind == .anthropic,
                                                      effort: "high", maxTokens: 64000)) { event in
            if case .status(let s) = event { statuses.append(s) }
        }
        wire.append(turn.assistantMessage)
        text += turn.text
        citations += turn.citations
        if turn.stopReason == .toolUse {
            var results: [ToolResult] = []
            for call in turn.toolCalls { results.append(await ResearchTools.run(call)) }
            wire += provider.toolResultMessages(results)
            continue
        }
        break
    }
    return (text, citations, wire, statuses)
}

let semaphore = DispatchSemaphore(value: 0)
Task {
    // Anthropic: research loop with a client tool (live arXiv), thinking block replay, citations.
    var anthropic = AnthropicProvider(apiKey: "test-key", model: "claude-opus-5-5", serverFallback: true)
    anthropic.endpoint = URL(string: base + "/v1/messages")!
    do {
        let (text, citations, wire, statuses) = try await researchLoop(anthropic, question: "什么是 KAN？")
        check(text.contains("我先检索文献。") && text.contains("$\\phi(x)"), "Anthropic: streamed text across two calls")
        check(citations.first?.url == "https://arxiv.org/abs/2404.19756", "Anthropic: citation")
        check(statuses.contains { $0.contains("Kolmogorov-Arnold networks") }, "Anthropic: tool status with streamed query")
        let toolResult = wire[1]["content"]?[0]
        check(toolResult?["type"]?.string == "tool_result" && toolResult?["tool_use_id"]?.string == "toolu_01", "Anthropic: tool_result message")
        let arxiv = toolResult?["content"]?.string ?? ""
        // An external service: results, or a quick error (rate limit, timeout) that the model can work around.
        check(arxiv.contains("Authors:") || arxiv.hasPrefix("Error"),
              "Live arXiv call (\(arxiv.contains("Authors:") ? "results" : "unavailable, failed fast")): \(arxiv.prefix(60))")
        let second = requests().last { $0["path"]?.string == "/v1/messages" }
        let replayed = second?["body"]?["messages"]?[1]
        check(replayed?["content"]?[0]?["signature"]?.string == "sig-1", "Anthropic: thinking block replayed unchanged")
        check(second?["headers"]?["anthropic-beta"]?.string == "server-side-fallback-2026-07-01", "Anthropic: fallback beta header")
        check(second?["body"]?["fallbacks"]?.string == "default", "Anthropic: fallbacks default")
    } catch {
        check(false, "Anthropic research loop threw \(error)")
    }

    // Anthropic: structured pet reply.
    do {
        let turn = try await anthropic.send(LLMRequest(system: "pet", messages: [anthropic.userMessage("hi")], effort: "low",
                                                       maxTokens: 4000, jsonSchema: PetReply.schema))
        let reply = PetReply.parse(turn.text)
        check(reply.motion == .happy && reply.reply.hasPrefix("你好呀"), "Anthropic: structured pet reply")
    } catch {
        check(false, "Anthropic pet reply threw \(error)")
    }

    // Anthropic: authentication error surfaces the API message.
    var wrong = AnthropicProvider(apiKey: "wrong", model: "claude-opus-5-5", serverFallback: false)
    wrong.endpoint = anthropic.endpoint
    do {
        _ = try await wrong.send(LLMRequest(system: "s", messages: [wrong.userMessage("x")], maxTokens: 10))
        check(false, "Anthropic: wrong key should fail")
    } catch {
        check(error.localizedDescription == "HTTP 401: invalid x-api-key", "Anthropic: HTTP error message (\(error.localizedDescription))")
    }

    // OpenAI-compatible: research loop with live Semantic Scholar.
    let openai = OpenAICompatibleProvider(apiKey: "", baseURL: base + "/v1/", model: "mock-model")
    do {
        let (text, _, wire, _) = try await researchLoop(openai, question: "GNN")
        check(text == "检索完成，结论如下。", "OpenAI: final text after tool call")
        let toolMessage = wire[1]
        check(toolMessage["role"]?.string == "tool" && toolMessage["tool_call_id"]?.string == "call_1", "OpenAI: tool message")
        let content = toolMessage["content"]?.string ?? ""
        let s2ok = content.contains("URL:") || content.contains("HTTP 429")
        check(s2ok, "Live Semantic Scholar call (results or rate limit): \(content.prefix(80))")
    } catch {
        check(false, "OpenAI research loop threw \(error)")
    }

    // OpenAI-compatible: JSON-mode pet reply with a reminder; tools omitted when disabled.
    do {
        let turn = try await openai.send(LLMRequest(system: "pet json", messages: [openai.userMessage("半小时后提醒我开会")],
                                                    tools: ResearchTools.specs, maxTokens: 100, jsonSchema: PetReply.schema,
                                                    toolChoiceNone: true))
        let reply = PetReply.parse(turn.text)
        check(reply.remind == RemindRequest(minutes: 30, text: "开会"), "OpenAI: JSON-mode reply with reminder")
        let last = requests().last
        check(last?["body"]?["response_format"]?["type"]?.string == "json_object", "OpenAI: JSON mode requested")
        check(last?["body"]?["tools"] == nil, "OpenAI: tools omitted when disabled and unused")
    } catch {
        check(false, "OpenAI pet reply threw \(error)")
    }
    // Live data sources for the daily tasks (network required).
    let news = await ResearchTools.run(ToolCall(id: "n", name: "search_news", input: ["query": "人工智能", "max_results": 3]))
    check(!news.isError && news.content.contains("URL: http"), "Live news search: \(news.content.prefix(60))")
    let quotes = await ResearchTools.run(ToolCall(id: "q", name: "get_stock_quotes", input: ["symbols": ["NVDA", "600519"]]))
    check(!quotes.isError && quotes.content.contains("(NVDA)") && quotes.content.contains("600519.SS"), "Live quotes: \(quotes.content.prefix(90))")
    let weather = await ResearchTools.run(ToolCall(id: "wx", name: "get_weather", input: ["location": "杭州", "days": 2]))
    check(!weather.isError && weather.content.contains("°C") && weather.content.split(separator: "\n").count >= 3,
          "Live weather: \(weather.content.prefix(70))")
    let brief = await Weather.brief("Beijing")
    check(brief?.contains("°C") == true && brief?.contains("\n") == false, "Weather brief is one line: \(brief?.prefix(60) ?? "nil")")
    let local = await ResearchTools.run(ToolCall(id: "w", name: "fetch_webpage", input: ["url": "http://127.0.0.1:8799/"]))
    check(local.content.hasPrefix("Only public"), "fetch_webpage refuses local addresses")
    semaphore.signal()
}
semaphore.wait()
print(failures == 0 ? "Integration test passed." : "\(failures) integration checks failed.")
exit(failures == 0 ? 0 : 1)
