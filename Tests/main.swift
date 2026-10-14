import Foundation

// Self-test for the platform-independent logic (Sources/Core, Sources/LLM). Run: scripts/selftest.sh

var failures = 0
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ name: String, file: String = #file, line: Int = #line) {
    checks += 1
    if !condition() {
        failures += 1
        print("FAIL \(name) (line \(line))")
    }
}

func sse(_ text: String) -> [SSEEvent] {
    var splitter = SSELineSplitter()
    var parser = SSEParser()
    var events: [SSEEvent] = []
    for byte in Array(text.utf8) {  // byte-by-byte: multi-byte characters straddle "chunks"
        if let line = splitter.append(byte), let e = parser.consume(line: line) { events.append(e) }
    }
    if let line = splitter.finish(), let e = parser.consume(line: line) { events.append(e) }
    if let e = parser.finish() { events.append(e) }
    return events
}

// MARK: SSE

do {
    let events = sse("event: message_start\ndata: {\"t\":\"你好🌸\"}\n\n: keep-alive comment\nevent: ping\r\ndata: {}\r\n\r\ndata: line1\ndata: line2\n\ndata: [DONE]")
    check(events.count == 4, "SSE event count")
    check(events[0] == SSEEvent(event: "message_start", data: "{\"t\":\"你好🌸\"}"), "SSE UTF-8 across bytes")
    check(events[1].event == "ping" && events[1].data == "{}", "SSE CRLF and comments")
    check(events[2].data == "line1\nline2", "SSE multi-line data")
    check(events[3].data == "[DONE]", "SSE trailing event without blank line")
}

// MARK: Anthropic stream accumulator

func anthropicTurn(_ lines: [String]) throws -> (LLMTurn, [LLMStreamEvent]) {
    var acc = AnthropicStreamAccumulator()
    var out: [LLMStreamEvent] = []
    for l in lines { out += try acc.consume(SSEEvent(event: nil, data: l)) }
    return (try acc.finish(), out)
}

do {
    let (turn, events) = try anthropicTurn([
        #"{"type":"message_start","message":{"model":"claude-opus-5-5"}}"#,
        #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
        #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig"}}"#,
        #"{"type":"content_block_stop","index":0}"#,
        #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
        #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Let me "}}"#,
        #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"search."}}"#,
        #"{"type":"content_block_delta","index":1,"delta":{"type":"citations_delta","citation":{"type":"web_search_result_location","url":"https://a.org","title":"A"}}}"#,
        #"{"type":"content_block_stop","index":1}"#,
        #"{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_1","name":"search_arxiv","input":{}}}"#,
        #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"query\": \"KAN"}}"#,
        #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":" networks\"}"}}"#,
        #"{"type":"content_block_stop","index":2}"#,
        #"{"type":"message_delta","delta":{"stop_reason":"tool_use"}}"#,
        #"{"type":"message_stop"}"#,
    ])
    check(turn.text == "Let me search.", "Anthropic text")
    check(turn.stopReason == .toolUse, "Anthropic stop reason")
    check(turn.toolCalls.count == 1 && turn.toolCalls[0].input["query"]?.string == "KAN networks", "Anthropic tool input")
    check(turn.citations == [Citation(title: "A", url: "https://a.org")], "Anthropic citations")
    check(turn.model == "claude-opus-5-5", "Anthropic model")
    let content = turn.assistantMessage["content"]?.array ?? []
    check(content.count == 3 && content[0]["signature"]?.string == "sig", "Anthropic thinking block kept for replay")
    check(events.contains { if case .status = $0 { return true }; return false }, "Anthropic tool status event")
}

do {
    var threw = false
    do { _ = try anthropicTurn([#"{"type":"message_delta","delta":{"stop_reason":"refusal","stop_details":{"category":"cyber"}}}"#]) }
    catch LLMError.refusal(let category) { threw = category == "cyber" }
    check(threw, "Anthropic refusal throws with category")

    var apiError = false
    do { _ = try anthropicTurn([#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#]) }
    catch LLMError.api(let message) { apiError = message == "Overloaded" }
    check(apiError, "Anthropic stream error event")
}

do {
    let blocks: [[String: JSON]] = [
        ["type": "thinking", "thinking": "", "signature": "x"],
        ["type": "text", "text": "partial"],
        ["type": "server_tool_use", "id": "srv_1", "name": "web_search"],
        ["type": "server_tool_use", "id": "srv_2", "name": "web_search"],
        ["type": "web_search_tool_result", "tool_use_id": "srv_1", "content": []],
        ["type": "tool_use", "id": "toolu_x", "name": "search_arxiv"],
        ["type": "fallback", "from": ["model": "claude-opus-5-5"], "to": ["model": "claude-opus-5"]],
        ["type": "thinking", "thinking": "", "signature": "y"],
        ["type": "text", "text": "rest"],
    ]
    let kept = AnthropicStreamAccumulator.sanitizedForReplay(blocks).map { $0["type"]?.string ?? "" }
    check(kept == ["text", "server_tool_use", "web_search_tool_result", "thinking", "text"], "Fallback replay sanitising")
}

// MARK: Anthropic request body

do {
    let opus = AnthropicProvider(apiKey: "k", model: "claude-opus-5-5", serverFallback: true)
    let haiku = AnthropicProvider(apiKey: "k", model: "claude-haiku-5-5", serverFallback: true)
    let request = LLMRequest(system: "s", messages: [opus.userMessage("hi")], tools: ResearchTools.specs, webSearch: true,
                             effort: "low", maxTokens: 100, jsonSchema: PetReply.schema, toolChoiceNone: true)
    let body = opus.body(for: request)
    check(body["fallbacks"]?.string == "default", "Fallbacks for Opus 5.5")
    check(haiku.body(for: request)["fallbacks"] == nil, "No fallbacks for Haiku")
    check(body["tool_choice"]?["type"]?.string == "none", "tool_choice none")
    check(body["thinking"] == nil, "No thinking parameter")
    check(body["output_config"]?["effort"]?.string == "low", "Effort")
    check(body["output_config"]?["format"]?["type"]?.string == "json_schema", "Structured output")
    check(body["tools"]?.array?.last?["type"]?.string == "web_search_20260209", "Web search tool version")
    check(body["cache_control"]?["type"]?.string == "ephemeral", "Automatic caching")
    check(opus.body(for: request).data() == body.data(), "Byte-stable request body")
}

// MARK: OpenAI stream accumulator

do {
    var acc = OpenAIStreamAccumulator()
    let chunks = [
        #"{"model":"deepseek-chat","choices":[{"delta":{"role":"assistant","content":"Hi"}}]}"#,
        #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"search_arxiv","arguments":"{\"que"}}]}}]}"#,
        #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"ry\":\"LLM\"}"}}]}}]}"#,
        #"{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#,
    ]
    for c in chunks { _ = try acc.consume(c) }
    let turn = acc.finish()
    check(turn.text == "Hi", "OpenAI text")
    check(turn.stopReason == .toolUse, "OpenAI stop reason")
    check(turn.toolCalls.first?.input["query"]?.string == "LLM", "OpenAI tool arguments across chunks")
    check(turn.assistantMessage["tool_calls"]?[0]?["function"]?["arguments"]?.string == #"{"query":"LLM"}"#, "OpenAI replay message")

    var errorAcc = OpenAIStreamAccumulator()
    var threw = false
    do { _ = try errorAcc.consume(#"{"error":{"message":"bad key"}}"#) } catch LLMError.api(let m) { threw = m == "bad key" }
    check(threw, "OpenAI stream error")
}

// MARK: Tool-call markup written as text (DeepSeek DSML)

do {
    let markup = "好的，我来查一下。\n<｜｜DSML｜｜ calls>\n<｜｜DSML｜｜ invoke name=\"get_stock_quotes\">\n"
        + "<｜｜DSML｜｜ parameter name=\"symbols\" string=\"true\">[\"^IXIC\", \"NVDA\"]</｜｜DSML｜｜ parameter>\n"
        + "</｜｜DSML｜｜ invoke>\n<｜｜DSML｜｜ invoke name=\"search_news\">\n"
        + "<｜｜DSML｜｜ parameter name=\"query\" string=\"true\">AI 新闻</｜｜DSML｜｜ parameter>\n"
        + "<｜｜DSML｜｜ parameter name=\"max_results\" string=\"false\">5</｜｜DSML｜｜ parameter>\n"
        + "</｜｜DSML｜｜ invoke>\n</｜｜DSML｜｜ calls>"
    var acc = OpenAIStreamAccumulator()
    var shown = ""
    let chars = Array(markup)
    var i = 0
    while i < chars.count {  // 3-character chunks split the markers
        let piece = String(chars[i..<min(i + 3, chars.count)])
        let chunk: JSON = ["choices": [["delta": ["content": .string(piece)]]]]
        for e in try acc.consume(chunk.compactString) { if case .text(let t) = e { shown += t } }
        i += 3
    }
    _ = try acc.consume(#"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#)
    let turn = acc.finish()
    check(shown == "好的，我来查一下。\n" && turn.text == "好的，我来查一下。", "Markup hidden from the stream (\(shown.debugDescription))")
    check(turn.stopReason == .toolUse && turn.toolCalls.map(\.name) == ["get_stock_quotes", "search_news"], "Markup parsed into tool calls")
    check(turn.toolCalls.first?.input["symbols"]?.array?.count == 2, "JSON array parameter")
    check(turn.toolCalls.last?.input["max_results"]?.int == 5 && turn.toolCalls.last?.input["query"]?.string == "AI 新闻", "Typed parameters")

    var plain = OpenAIStreamAccumulator()
    var plainShown = ""
    for piece in ["价格 <", "｜ 不是标记", "，a<｜b"] {
        for e in try plain.consume((["choices": [["delta": ["content": .string(piece)]]]] as JSON).compactString) {
            if case .text(let t) = e { plainShown += t }
        }
    }
    let plainTurn = plain.finish()
    check(plainTurn.text == "价格 <｜ 不是标记，a<｜b" && plainTurn.toolCalls.isEmpty, "Ordinary text with <｜ kept (\(plainTurn.text))")
}

// MARK: Pet reply parsing

do {
    let a = PetReply.parse(#"{"reply":"你好","motion":"happy","remind":null}"#)
    check(a == PetReply(reply: "你好", motion: .happy, remind: nil), "PetReply JSON")
    let b = PetReply.parse("好的！\n```json\n{\"reply\":\"半小时后叫你\",\"motion\":\"nod\",\"remind\":{\"minutes\":30,\"text\":\"开会\"}}\n```")
    check(b.remind == RemindRequest(minutes: 30, text: "开会") && b.motion == .nod, "PetReply fenced JSON with reminder")
    let c = PetReply.parse(#"Sure: {"reply":"ok","motion":"dance"} done"#)
    check(c.reply == "ok" && c.motion == .idle, "PetReply prose and unknown motion")
    let d = PetReply.parse("just text")
    check(d.reply == "just text" && d.motion == .idle, "PetReply plain-text fallback")
}

// MARK: Reminder rules

do {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    func at(_ day: Int, _ h: Int, _ m: Int) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: h, minute: m))!  // 2026-10-13 is a Tuesday
    }
    var config = ReminderConfig()
    config.sedentaryEnabled = false
    var state = ReminderState()

    var due = ReminderRules.evaluate(now: at(13, 11, 59), idleSeconds: 0, config: config, state: &state, calendar: cal)
    check(due.isEmpty, "No meal before time")
    due = ReminderRules.evaluate(now: at(13, 12, 5), idleSeconds: 0, config: config, state: &state, calendar: cal)
    check(due == [.meal(time: "12:00")], "Meal fires within grace")
    due = ReminderRules.evaluate(now: at(13, 12, 10), idleSeconds: 0, config: config, state: &state, calendar: cal)
    check(due.isEmpty, "Meal fires once")
    due = ReminderRules.evaluate(now: at(13, 19, 30), idleSeconds: 0, config: config, state: &state, calendar: cal)
    check(due.isEmpty, "No meal after grace window")
    due = ReminderRules.evaluate(now: at(14, 12, 1), idleSeconds: 0, config: config, state: &state, calendar: cal)
    check(due == [.meal(time: "12:00")], "Next day fires again")

    var weekend = ReminderState()
    due = ReminderRules.evaluate(now: at(17, 9, 1), idleSeconds: 0, config: config, state: &weekend, calendar: cal)  // Saturday
    check(!due.contains(.workStart), "No work reminder on weekends")
    var weekday = ReminderState()
    due = ReminderRules.evaluate(now: at(13, 9, 1), idleSeconds: 0, config: config, state: &weekday, calendar: cal)
    check(due.contains(.workStart), "Work reminder on weekdays")

    var sit = ReminderConfig()
    sit.mealsEnabled = false; sit.workEnabled = false; sit.sedentaryMinutes = 60
    var s = ReminderState()
    _ = ReminderRules.evaluate(now: at(13, 14, 0), idleSeconds: 0, config: sit, state: &s, calendar: cal)
    due = ReminderRules.evaluate(now: at(13, 14, 59), idleSeconds: 0, config: sit, state: &s, calendar: cal)
    check(due.isEmpty, "Sedentary not before interval")
    due = ReminderRules.evaluate(now: at(13, 15, 0), idleSeconds: 0, config: sit, state: &s, calendar: cal)
    check(due == [.sedentary], "Sedentary after interval")
    _ = ReminderRules.evaluate(now: at(13, 15, 30), idleSeconds: 600, config: sit, state: &s, calendar: cal)
    check(s.activeSince == nil, "Being away resets activity")

    var p = ReminderState(pending: [PendingNote(due: at(13, 10, 0), text: "meeting")])
    due = ReminderRules.evaluate(now: at(13, 10, 0), idleSeconds: 0, config: sit, state: &p, calendar: cal)
    check(due.count == 1 && p.pending.isEmpty, "Pending note fires and is removed")
    check(ReminderRules.date("25:00", on: Date(), cal) == nil, "Malformed time rejected")
}

// MARK: arXiv parser

do {
    let xml = """
    <feed xmlns="http://www.w3.org/2005/Atom"><entry><id>http://arxiv.org/abs/2404.19756v1</id>
    <published>2024-04-30T17:58:29Z</published><title>KAN:
      Kolmogorov-Arnold Networks</title><summary> Inspired by the theorem </summary>
    <author><name>Ziming Liu</name></author><author><name>Max Tegmark</name></author>
    <link href="http://arxiv.org/abs/2404.19756v1" rel="alternate" type="text/html"/></entry></feed>
    """
    let entries = ArxivAtomParser.parse(Data(xml.utf8))
    check(entries.count == 1 && entries[0].title == "KAN: Kolmogorov-Arnold Networks", "arXiv title")
    check(entries.first?.authors == ["Ziming Liu", "Max Tegmark"], "arXiv authors")
    check(entries.first?.url == "http://arxiv.org/abs/2404.19756v1", "arXiv URL")
}

// MARK: Weather helpers

do {
    let w = PetReply.parse(#"{"reply":"我查一下～","motion":"think","remind":null,"weather_city":"北京"}"#)
    check(w.weatherCity == "北京" && w.motion == .think, "PetReply weather_city")
    let n = PetReply.parse(#"{"reply":"好","motion":"nod","remind":null,"weather_city":null}"#)
    check(n.weatherCity == nil, "PetReply null weather_city")
    let schemaFields = PetReply.schema["required"]?.array?.compactMap(\.string) ?? []
    check(schemaFields.contains("weather_city"), "Schema requires weather_city")
    check(!Weather.describe(0).isEmpty && Weather.describe(63) != Weather.describe(-1), "WMO weather codes")
}

// MARK: Memory bank and weather alerts

do {
    check(MemoryText.isDuplicate("主人对花生过敏", "主人对花生过敏。"), "Memory duplicate: punctuation")
    check(MemoryText.isDuplicate("主人 11 月 20 日答辩", "主人11月20日要答辩"), "Memory duplicate: rewording")
    check(!MemoryText.isDuplicate("主人对花生过敏", "主人喜欢喝美式咖啡"), "Different memories kept apart")
    check(!MemoryText.isDuplicate("主人养了一只猫", "主人养了一只狗"), "Similar wording, different fact")
    let r = PetReply.parse(#"{"reply":"记住啦","motion":"nod","remind":null,"weather_city":null,"remember":"主人对花生过敏","forget":null}"#)
    check(r.remember == "主人对花生过敏" && r.forget == nil, "PetReply remember")
    let f = PetReply.parse(#"{"reply":"好","motion":"nod","remind":null,"weather_city":null,"remember":" ","forget":"花生"}"#)
    check(f.remember == nil && f.forget == "花生", "PetReply forget, blank remember ignored")

    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    let noon = cal.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 12))!
    func hour(_ h: Double, code: Int = 3, p: Double = 10, wind: Double = 10) -> WeatherSnapshot.Hour {
        .init(time: noon.addingTimeInterval(h * 3600), code: code, temperature: 20, precipitationProbability: p, precipitation: 0, windSpeed: wind)
    }
    var snap = WeatherSnapshot(place: "杭州", currentCode: 2, currentPrecipitation: 0,
                               hours: [hour(1), hour(2, code: 61, p: 70), hour(3, code: 63, p: 80)],
                               todayMax: 24, tomorrowMax: 16, tomorrowMin: 11, tomorrowCode: 61, tomorrowPrecipitationProbability: 80)
    var state = WeatherAlertState()
    var alerts = WeatherAlerts.evaluate(snap, now: noon, state: &state, calendar: cal)
    check(alerts == [.precipitationSoon(minutes: 120, probability: 70, snow: false)], "Rain in two hours announced (\(alerts))")
    alerts = WeatherAlerts.evaluate(snap, now: noon.addingTimeInterval(1200), state: &state, calendar: cal)
    check(alerts.isEmpty, "Rain alert not repeated within six hours")

    snap.currentCode = 61
    var wet = WeatherAlertState()
    check(WeatherAlerts.evaluate(snap, now: noon, state: &wet, calendar: cal).isEmpty, "No rain alert while it already rains")

    snap.hours = [hour(4, code: 95, p: 80)]
    var storm = WeatherAlertState()
    alerts = WeatherAlerts.evaluate(snap, now: noon, state: &storm, calendar: cal)
    check(alerts.contains { if case .severe(_, let d) = $0 { return d == WeatherAlerts.severeDescription(95) }; return false }, "Thunderstorm announced")
    snap.hours = [hour(2, wind: 60)]
    var windy = WeatherAlertState()
    check(WeatherAlerts.evaluate(snap, now: noon, state: &windy, calendar: cal).contains { if case .severe = $0 { return true }; return false }, "Strong wind announced")

    let evening = noon.addingTimeInterval(7 * 3600)  // 19:00
    snap.hours = []
    var tomorrow = WeatherAlertState()
    alerts = WeatherAlerts.evaluate(snap, now: evening, state: &tomorrow, calendar: cal)
    check(alerts == [.tomorrow(temperatureChange: -8, rainProbability: 80)], "Evening: colder and rainy tomorrow (\(alerts))")
    check(WeatherAlerts.evaluate(snap, now: evening.addingTimeInterval(1800), state: &tomorrow, calendar: cal).isEmpty, "Tomorrow alert once per day")
    var morning = WeatherAlertState()
    check(WeatherAlerts.evaluate(snap, now: noon, state: &morning, calendar: cal).isEmpty, "No tomorrow alert before 17:00")
    check(WeatherAlerts.message(.tomorrow(temperatureChange: -8, rainProbability: nil), place: "杭州").text.contains("8"), "Alert text")

    let memFile = FileManager.default.temporaryDirectory.appendingPathComponent("memories-\(UUID().uuidString).json")
    let store = MemoryStore(file: memFile)
    check(store.add("主人对花生过敏") && store.add("主人养了一只猫"), "Memories added")
    check(!store.add("主人对花生过敏。"), "Exact duplicate not stored again")
    check(store.add("主人对花生严重过敏") && store.items.count == 2 && store.items.contains { $0.text == "主人对花生严重过敏" },
          "Near-duplicate replaces older wording")
    check(MemoryStore(file: memFile).items.count == 2, "Memories persisted to disk")
    check(store.promptSection.contains("主人养了一只猫") && store.promptSection.contains("记忆库"), "Memories in prompt section")
    check(store.forget("花生") == 1 && store.items.map(\.text) == ["主人养了一只猫"], "Forget by keyword")
    store.removeAll()
    check(store.promptSection.isEmpty && MemoryStore(file: memFile).items.isEmpty, "Clear all memories")
    try? FileManager.default.removeItem(at: memFile)
}

// MARK: News / quotes / web page helpers

do {
    check(ResearchTools.yahooSymbol("600519") == "600519.SS", "A-share Shanghai code")
    check(ResearchTools.yahooSymbol("000001") == "000001.SZ", "A-share Shenzhen code")
    check(ResearchTools.yahooSymbol("sz300750") == "300750.SZ", "Prefixed A-share code")
    check(ResearchTools.yahooSymbol("nvda") == "NVDA" && ResearchTools.yahooSymbol("^IXIC") == "^IXIC", "Yahoo symbols kept")
    check(ResearchTools.isPrivateHost("localhost") && ResearchTools.isPrivateHost("192.168.1.2")
          && ResearchTools.isPrivateHost("10.0.0.8") && ResearchTools.isPrivateHost("172.20.1.1")
          && ResearchTools.isPrivateHost("router"), "Private hosts refused")
    check(!ResearchTools.isPrivateHost("www.bing.com") && !ResearchTools.isPrivateHost("8.8.8.8"), "Public hosts allowed")
    let text = ResearchTools.readableText("<html><head><title>x</title></head><body><script>var a=1;</script><h1>标题</h1><p>第一段&amp;内容</p><style>p{}</style></body></html>")
    check(text == "标题\n第一段&内容", "Readable text extraction (\(text))")
    let rss = """
    <?xml version="1.0"?><rss version="2.0" xmlns:News="https://www.bing.com/news"><channel><title>t</title>
    <item><title>AI 新闻</title><link>https://example.com/a</link><description><![CDATA[<b>摘要</b>内容]]></description>
    <pubDate>Tue, 13 Oct 2026 08:00:00 GMT</pubDate><News:Source>Example</News:Source></item></channel></rss>
    """
    let items = RSSParser.parse(Data(rss.utf8))
    check(items.count == 1 && items[0].title == "AI 新闻" && items[0].source == "Example" && items[0].date != nil, "RSS parsing")
    check(items.first?.summary == "摘要 内容", "RSS summary without markup (\(items.first?.summary ?? ""))")
}

print(failures == 0 ? "All \(checks) checks passed." : "\(failures) of \(checks) checks failed.")
exit(failures == 0 ? 0 : 1)
