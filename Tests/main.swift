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
    check(schemaFields.contains("open_app") && schemaFields.contains("add_event") && schemaFields.contains("agent_task"),
          "Schema requires open_app, add_event and agent_task")
    let lid = PetReply.parse(#"{"reply":"确认一下授权就好","motion":"nod","lid_awake":true}"#)
    check(lid.lidAwake == true && PetReply.parse(#"{"reply":"好","motion":"nod","lid_awake":null}"#).lidAwake == nil, "PetReply lid_awake")
    check(schemaFields.contains("lid_awake"), "Schema requires lid_awake")
    let job = PetReply.parse(#"{"reply":"确认后我就去办","motion":"nod","agent_task":"在工作目录新建 todo.md","open_app":null}"#)
    check(job.agentTask == "在工作目录新建 todo.md" && job.openApp == nil, "PetReply agent_task")
    check(schemaFields.contains("claude_task"), "Schema requires claude_task")
    let cc = PetReply.parse(#"{"reply":"交给 Claude 了","motion":"nod","claude_task":{"task":"修复 build.sh 的签名","dir":" "}}"#)
    check(cc.claudeTask == ClaudeTaskRequest(task: "修复 build.sh 的签名", dir: nil), "PetReply claude_task, blank dir is the default")
    let quote = ClaudeTaskRequest(task: "改 it's \"build\" $HOME", dir: nil).shellCommand(claude: "/opt/homebrew/bin/claude", dir: "/a b")
    check(quote == #"cd '/a b' && '/opt/homebrew/bin/claude' '改 it'\''s "build" $HOME'"#, "Claude task shell quoting (\(quote))")
    let app = PetReply.parse(#"{"reply":"好","motion":"nod","open_app":" 微信 ","add_event":null}"#)
    check(app.openApp == "微信" && app.addEvent == nil, "PetReply open_app")
    let ev = PetReply.parse(#"{"reply":"确认一下","motion":"nod","open_app":null,"add_event":{"title":"组会","start":"2026-10-22 15:00","end":null,"location":" ","all_day":false}}"#)
    check(ev.addEvent == EventRequest(title: "组会", start: "2026-10-22 15:00", end: nil, location: nil, allDay: false), "PetReply add_event")
    var shanghai = Calendar(identifier: .gregorian)
    shanghai.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    if let (s, e) = ev.addEvent?.interval(calendar: shanghai) {
        check(e.timeIntervalSince(s) == 3600 && shanghai.component(.hour, from: s) == 15, "Event: one hour by default")
    } else { check(false, "Event interval") }
    let allDay = EventRequest(title: "休假", start: "2026-10-22", end: "2026-10-23", location: nil, allDay: true)
    if let (s, e) = allDay.interval(calendar: shanghai) {
        check(e.timeIntervalSince(s) == 2 * 86400, "All-day event over two days")
    } else { check(false, "All-day interval") }
    check(EventRequest(title: "x", start: "明天下午", end: nil, location: nil).interval() == nil, "Unreadable start refused")
    let back = EventRequest(title: "x", start: "2026-10-22 15:00", end: "2026-10-22 14:00", location: nil)
    check(back.interval(calendar: shanghai).map { $0.end.timeIntervalSince($0.start) } == 3600, "End before start: one hour")
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

// MARK: Layered memory: forgetting, recall, consolidation, inner thoughts

do {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 20))!
    let day = 86400.0

    // Files of earlier versions (id, text, created, source) still load, as facts.
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let legacy = try? decoder.decode([Memory].self, from: Data(#"[{"id":"7D3F7E0B-2C1A-4C9E-9C7A-1B2D3E4F5A6B","text":"主人对花生过敏","created":"2026-10-12T08:00:00Z","source":"manual"}]"#.utf8))
    check(legacy?.first?.kind == .fact && legacy?.first?.importance == 8 && legacy?.first?.pinned == true, "Legacy memory loads as a pinned fact")
    var roundTrip = Memory(text: "主人组会被导师批评", kind: .episode, importance: 7, created: now)
    roundTrip.followUp = now.addingTimeInterval(day)
    roundTrip.followUpNote = "后来怎么样"
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    check((try? decoder.decode(Memory.self, from: encoder.encode(roundTrip))) == roundTrip, "Memory round trip with the new fields")

    // The forgetting curve (MemoryBank).
    var e = Memory(text: "主人组会被导师批评", kind: .episode, importance: 5, created: now.addingTimeInterval(-10 * day))
    check(abs(e.strengthDays - 10) < 1e-9 && abs(e.retention(at: now) - exp(-1)) < 1e-9, "Episode retention after the forgetting curve")
    check(!e.faded(at: now) && e.faded(at: now.addingTimeInterval(16 * day)), "Unrecalled episode fades after about 25 days")
    e.recall(at: now)
    check(e.recalls == 1 && e.strengthDays == 20 && e.retention(at: now) == 1, "Recall restarts the curve and doubles the strength")
    e.recall(at: now.addingTimeInterval(3600))
    check(e.recalls == 1, "One recall in six hours")
    var waiting = Memory(text: "主人下周考试", kind: .episode, importance: 1, created: now.addingTimeInterval(-60 * day))
    waiting.followUp = now
    check(!waiting.faded(at: now), "A pending follow-up keeps the episode")
    check(!Memory(text: "主人喜欢猫", importance: 1, created: now.addingTimeInterval(-900 * day)).faded(at: now), "Facts never fade")
    check(!Memory(text: "主人去了海边", kind: .episode, importance: 1, source: "manual", created: now.addingTimeInterval(-900 * day)).faded(at: now),
          "Manual entries never fade")

    // Relevance without word segmentation; words every memory shares count for little.
    let texts = ["主人对花生过敏", "10 月 27 日主人说组会被导师批评了，有些沮丧", "主人喜欢喝美式咖啡", "主人 11 月 20 日答辩",
                 "主人养了一只叫团子的猫", "主人在写关于图神经网络的论文"]
    func best(_ query: String) -> Int? {
        let scores = MemoryRecall.lexicalScores(query: query, texts: texts)
        guard let top = scores.max(), top > 0 else { return nil }
        return scores.firstIndex(of: top)
    }
    check(best("明天组会要汇报，好紧张") == 1, "Recall by a shared word")
    check(best("帮我想想答辩 PPT 怎么做") == 3, "Recall of a date by its event")
    check(best("猫怎么样了") == 4, "Recall by a one-character word")
    check(best("你好") == nil && best("主人") == nil || MemoryRecall.lexicalScores(query: "主人", texts: texts).max()! < 0.1,
          "A greeting or the shared word alone recalls nothing")
    let terms = MemoryRecall.terms("GNN 论文")
    check(terms["gnn"] == 1 && terms["论文"] == 1 && terms["论"] == 0.5, "Terms: Latin words, Chinese bigrams and characters")

    // Ranking (Generative Agents): relevance outweighs recency; embeddings count by their spread.
    let lunch = Memory(text: "主人中午吃了牛肉面", kind: .episode, importance: 3, created: now.addingTimeInterval(-3600))
    let meeting = Memory(text: "主人组会被导师批评，有些沮丧", kind: .episode, importance: 6, created: now.addingTimeInterval(-2 * day))
    let ranked = MemoryRecall.rank([lunch, meeting], query: "组会的事我想了想", now: now)
    check(ranked.first?.memory.id == meeting.id && ranked.first?.relevance == 1 && ranked.last!.relevance < 0.3,
          "Relevance in the ranking (\(ranked.map(\.relevance)))")
    let semantic = MemoryRecall.rank([lunch, meeting], query: "心情不好", now: now, semantic: [0.6, 0.7])
    check(semantic.first?.memory.id == meeting.id && abs(semantic.first!.relevance - 0.5) < 1e-9, "Semantic similarity counts by its spread")
    let firstLine = MemoryRecall.line(ranked[0].memory, now: now, calendar: cal)
    check(MemoryRecall.select(ranked, budget: firstLine.count + 1, now: now, calendar: cal).count == 1, "Selection within the budget")
    var planned = meeting
    planned.followUp = cal.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 19))
    planned.followUpNote = "和导师沟通得怎么样"
    let rendered = MemoryRecall.render([planned, Memory(text: "主人对花生过敏", created: now)], now: now, calendar: cal)
    check(rendered.contains("[2026-10-26，前天] 主人组会被导师批评") && rendered.contains("打算 2026-10-29 19:00 问问：和导师沟通得怎么样"),
          "Episode line with its day and follow-up (\(rendered))")
    check(rendered.range(of: "### 关于主人的长期事实")!.lowerBound < rendered.range(of: "### 经历")!.lowerBound, "Facts before episodes")

    // Consolidation output.
    let raw = """
    ```json
    {"episodes": [{"text": "10 月 28 日主人说明天上午有组会，要汇报进展", "importance": 12, "follow_up_at": "2026-10-29 14:00", "follow_up": "组会汇报顺利吗"},
                  {"text": "闲聊", "importance": 2, "follow_up_at": null, "follow_up": null},
                  {"text": "主人晚上吃了火锅", "importance": 3, "follow_up_at": "2025-01-01 10:00", "follow_up": "好吃吗"}],
     "facts": [{"text": "主人不吃香菜", "importance": 7}],
     "updates": [{"id": "f1", "text": "主人已戒咖啡"}, {"id": "E2", "text": null}],
     "insight": {"text": "主人这周压力较大", "importance": 6}}
    ```
    """
    let digest = MemoryDigest.parse(raw, now: now, calendar: cal)
    check(digest?.episodes.count == 2 && digest?.episodes.first?.importance == 10, "Digest: trivial episodes left out, importance clamped")
    check(digest?.episodes.first?.followUp == cal.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 14))
          && digest?.episodes.first?.followUpNote == "组会汇报顺利吗", "Digest: follow-up time and question")
    check(digest?.episodes.last?.followUp == nil && digest?.episodes.last?.followUpNote == nil, "Digest: a follow-up long past is dropped")
    check(digest?.facts == [.init(text: "主人不吃香菜", importance: 7)]
          && digest?.updates == [.init(label: "F1", text: "主人已戒咖啡"), .init(label: "E2", text: nil)], "Digest: facts, rewording and deletion")
    check(digest?.insight == .init(text: "主人这周压力较大", importance: 6), "Digest: impression")
    check(MemoryDigest.parse("对不起，这段对话没有可整理的内容。", now: now) == nil, "Unreadable digest")
    check(MemoryDigest.parseTime("2026-10-29", calendar: cal) == cal.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 19)), "A bare date is read as 19:00")
    let late = MemoryDigest.parse(#"{"episodes":[{"text":"主人下午去医院复查","importance":7,"follow_up_at":"2026-10-28 18:00","follow_up":"复查结果"}],"facts":[],"updates":[],"insight":null}"#,
                                  now: now, calendar: cal)
    check(late?.episodes.first?.followUp == now.addingTimeInterval(1800), "A follow-up just past moves to half an hour from now")

    // The store: consolidation with labels (manual entries stay as they are), follow-ups, core and recalled sections, forgetting.
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("layered-\(UUID().uuidString).json")
    let store = MemoryStore(file: file)
    store.calendar = cal
    store.add("主人每天喝咖啡")
    store.add("主人对花生过敏", source: "manual")
    let context = store.digestContext(for: "咖啡", at: now)
    check(context.text.contains("### 主人手动记下的（只读）") && context.labels.count == 1 && context.text.contains("- F1 [") , "Digest context labels all but manual entries")
    var update = MemoryDigest()
    update.updates = [.init(label: "F1", text: "主人已戒咖啡")]
    update.episodes = [.init(text: "主人说明天上午有组会要汇报", importance: 6, followUp: now.addingTimeInterval(3600), followUpNote: "组会顺利吗")]
    update.insight = .init(text: "主人这周压力较大", importance: 6)
    let applied = store.apply(update, labels: context.labels, at: now)
    check(applied.added == 2 && applied.changed == 1 && applied.removed == 0 && store.items.contains { $0.text == "主人已戒咖啡" }, "Digest applied (\(applied))")
    check(store.apply(update, labels: [:], at: now).added == 0, "The same digest again adds nothing")
    check(store.apply(MemoryDigest(updates: [.init(label: "F9", text: nil)]), labels: ["F9": store.items.first { $0.source == "manual" }!.id], at: now).removed == 0,
          "Manual entries are not changed by consolidation")
    let episode = store.items.first { $0.kind == .episode }!.id
    check(store.dueFollowUps(at: now).isEmpty && store.dueFollowUps(at: now.addingTimeInterval(3600)).map(\.id) == [episode], "Follow-up due at its time")
    store.postponeFollowUp(episode, retry: now.addingTimeInterval(7200))
    check(store.dueFollowUps(at: now.addingTimeInterval(7200)).count == 1, "Postponed follow-up")
    store.postponeFollowUp(episode, retry: now.addingTimeInterval(9000))
    store.postponeFollowUp(episode, retry: now.addingTimeInterval(9900))
    check(store.dueFollowUps(at: now.addingTimeInterval(day)).isEmpty, "Follow-up given up after three postponements")
    check(store.coreSection(at: now).contains("主人对花生过敏") && store.coreSection(at: now).contains("主人这周压力较大")
          && !store.coreSection(at: now).contains("组会"), "Core memories: pinned facts and impressions")
    let block = store.recallBlock(for: "组会准备得怎么样", at: now)
    check(block.text.contains("组会") && !block.text.contains("花生") && block.relevant == [episode], "Recalled memories beyond the core (\(block))")
    store.recall(block.relevant, at: now)
    check(MemoryStore(file: file).items.first { $0.id == episode }?.recalls == 1, "Recall strengthens the memory and is saved")
    var asked = MemoryDigest()
    asked.episodes = [.init(text: "主人周五要去医院复查", importance: 7, followUp: now.addingTimeInterval(600), followUpNote: "复查结果")]
    store.apply(asked, labels: [:], at: now)
    let checkup = store.items.first { $0.text == "主人周五要去医院复查" }!.id
    store.followedUp(checkup, at: now.addingTimeInterval(700))
    check(store.dueFollowUps(at: now.addingTimeInterval(day)).isEmpty && store.items.first { $0.id == checkup }?.recalls == 1, "Followed up: asked once, recalled")
    let gone = store.forgetFaded(at: now.addingTimeInterval(400 * day))
    check(gone.count == 3 && store.items.allSatisfy { $0.kind == .fact }, "Episodes and impressions fade, facts stay (\(gone.map(\.text)))")
    try? FileManager.default.removeItem(at: file)

    // Inner thoughts: the strongest is voiced at the threshold, repetitions are left out.
    let thoughts = InnerThoughts.parse(#"{"thoughts":[{"thought":"主人好像很累","say":"要不要歇一会儿？","motion":"sleepy","motivation":3,"follow_up":null},{"thought":"组会应该结束了","say":"组会顺利吗？","motion":"perk","motivation":4.5,"follow_up":"e1"},{"thought":"想打个哈欠","say":"","motion":"stretch","motivation":9,"follow_up":null}]}"#) ?? []
    check(thoughts.count == 3 && thoughts[1].followUp == "E1" && thoughts[1].motion == .perk && thoughts[2].motivation == 5, "Thoughts parsed, urge clamped")
    check((try? InnerThoughts.choose(thoughts, threshold: 3.5, recent: []).get())?.say == "组会顺利吗？", "The strongest thought is said")
    check(InnerThoughts.choose(thoughts, threshold: 5, recent: []) == .failure(.init(reason: .weak)), "Silent below the threshold")
    check((try? InnerThoughts.choose(thoughts, threshold: 3, recent: ["组会顺利吗"]).get())?.say == "要不要歇一会儿？", "A repetition gives way to the next thought")
    check(InnerThoughts.choose(thoughts, threshold: 4, recent: ["组会顺利吗"]) == .failure(.init(reason: .repeated)), "Silent rather than repeating")
    check(InnerThoughts.choose([thoughts[2]], threshold: 1, recent: []) == .failure(.init(reason: .empty)), "A thought without words stays a thought")
    check(InnerThoughts.threshold(base: 3.5, unanswered: 0) == 3.5 && InnerThoughts.threshold(base: 3.5, unanswered: 2) == 4.5
          && InnerThoughts.threshold(base: 3.5, unanswered: 9) == 5, "Unanswered remarks raise the threshold")
    check(InnerThoughts.parse("今天天气真好呀") == nil, "No thoughts in plain prose")
    check(InnerThoughts.similarity("组会顺利吗？", "组会顺利吗") > 0.99 && InnerThoughts.similarity("要喝点水吗", "组会顺利吗") < 0.2, "Remark similarity")
}

// MARK: Watching the screen

do {
    // Image messages in both wire formats.
    let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
    let a = AnthropicProvider(apiKey: "k", model: "claude-opus-5-5", serverFallback: false).imageMessage("看看", jpeg: jpeg)
    check(a["content"]?[0]?["type"]?.string == "image" && a["content"]?[0]?["source"]?["media_type"]?.string == "image/jpeg"
          && a["content"]?[0]?["source"]?["data"]?.string == jpeg.base64EncodedString() && a["content"]?[1]?["text"]?.string == "看看",
          "Anthropic image message: base64 image block before the text")
    let o = OpenAICompatibleProvider(apiKey: "k", baseURL: "http://127.0.0.1:1/v1", model: "m").imageMessage("看看", jpeg: jpeg)
    check(o["content"]?[0]?["text"]?.string == "看看" && o["content"]?[1]?["image_url"]?["url"]?.string == "data:image/jpeg;base64,/9j/2Q==",
          "OpenAI-compatible image message: data URL")

    // Apps left out, scenes not looked at again, screenshot size.
    check(!ScreenGlances.excluded(name: "1Password", list: ""), "Without a list every app is captured")
    check(ScreenGlances.excluded(name: "微信", list: "微信，招商银行") && ScreenGlances.excluded(name: "招商银行 Mac", list: "微信、招商银行")
          && !ScreenGlances.excluded(name: "Xcode", list: "微信, 招商银行"), "The owner's list, by name")
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let seen = ScreenGlance(date: t0, looked: t0, app: "Xcode", title: "PetMind.swift", activity: "在 Xcode 里写代码", kind: "work")
    check(ScreenGlances.sameScene(seen, app: "Xcode", title: "PetMind.swift", now: t0.addingTimeInterval(600)), "Same app and window: no new screenshot")
    check(!ScreenGlances.sameScene(seen, app: "Xcode", title: "PetBrain.swift", now: t0.addingTimeInterval(600))
          && !ScreenGlances.sameScene(seen, app: "Xcode", title: "PetMind.swift", now: t0.addingTimeInterval(1900))
          && !ScreenGlances.sameScene(seen, app: "Xcode", title: nil, now: t0.addingTimeInterval(60)), "Another window, half an hour later, or no title: look again")
    check(ScreenGlances.size(width: 2940, height: 1912) == (1280, 832) && ScreenGlances.size(width: 800, height: 600) == (800, 600),
          "Screenshot scaled to 1280 px on its longest side")

    // The model's account.
    check(ScreenGlances.parse(#"{"activity":"在 B 站看猫咪视频","kind":"leisure"}"#)! == ("在 B 站看猫咪视频", "leisure"), "Glance parsed")
    check(ScreenGlances.parse(#"{"activity":"在网银查看本月账单","kind":"other","private":true}"#)?.activity == "在网银查看本月账单",
          "Every screen is described as it is")
    check(ScreenGlances.parse(#"{"activity":"写论文","kind":"dreaming"}"#)?.kind == "other" && ScreenGlances.parse("看不清") == nil,
          "Unknown kind, unreadable account")
    check(ScreenGlances.contextLine(seen, now: t0.addingTimeInterval(180)) == "主人屏幕上（3 分钟前，工作）：在 Xcode 里写代码"
          && ScreenGlances.contextLine(seen, now: t0.addingTimeInterval(1300)) == nil, "Context line while fresh")
}

// MARK: Claude API spending (Admin API cost report)

do {
    let iso = ISO8601DateFormatter()
    let page = Data(#"{"data":[{"starting_at":"2026-10-01T00:00:00Z","ending_at":"2026-10-02T00:00:00Z","results":[{"amount":"250.5","currency":"USD"},{"amount":"49.5","currency":"USD"}]},{"starting_at":"2026-10-27T00:00:00Z","ending_at":"2026-10-28T00:00:00Z","results":[]},{"starting_at":"2026-10-28T00:00:00Z","ending_at":"2026-10-29T00:00:00Z","results":[{"amount":"123.45","currency":"USD"}]}],"has_more":true,"next_page":"page_x"}"#.utf8)
    let parsed = ClaudeCost.parse(page)
    check(parsed?.days.count == 3 && parsed?.days[iso.date(from: "2026-10-01T00:00:00Z")!] == 300 && parsed?.next == "page_x", "Cost report page parsed and added up per day")
    check(ClaudeCost.parse(Data(#"{"type":"error","error":{"message":"invalid x-api-key"}}"#.utf8)) == nil, "An error is not a cost report")
    let now = iso.date(from: "2026-10-28T13:00:00Z")!
    let cost = ClaudeCost(days: parsed!.days, fetched: now)
    check(cost.today == 123.45 && cost.month == 423.45, "Spent today and this month (UTC)")
    // A balance of $20 read at 06:00 UTC on Oct 28, when 23.45 cents of that day were already spent: 100 cents more since.
    let since = iso.date(from: "2026-10-28T06:00:00Z")!
    check(abs(cost.remaining(base: 20, since: since, offset: 23.45) - 19) < 1e-9, "Balance estimated from the one entered")
    check(cost.lines(base: 20, since: since, offset: 23.45) == ["今日（UTC）花费 $1.23", "本月（UTC）花费 $4.23", "估算余额 $19.00"]
          && cost.lines(base: 0, since: nil, offset: 0).count == 2, "Spending lines")
    let url = ClaudeCost.url(from: iso.date(from: "2026-10-05T17:30:00Z")!, page: "p2")?.absoluteString ?? ""
    check(url.hasPrefix("https://api.anthropic.com/v1/organizations/cost_report?") && url.contains("starting_at=2026-10-05T00:00:00Z")
          && url.contains("bucket_width=1d") && url.contains("limit=31") && url.contains("page=p2"), "Cost report URL from the UTC day (\(url))")
    check(ClaudeCost.monthStart(now) == iso.date(from: "2026-10-01T00:00:00Z"), "UTC month start")
}

// MARK: Claude usage (Claude Usage Widget files)

do {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cuw-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    check(ClaudeUsage.load(from: dir) == nil, "No widget files: no usage")
    let now = Date(timeIntervalSince1970: 1_792_570_000)
    func writeQuota(five: Double, fiveReset: Double, week: Double, captured: Double) {
        let json = #"{"fiveHour":{"usedPercent":\#(five),"resetsAt":\#(fiveReset)},"sevenDay":{"usedPercent":\#(week),"resetsAt":1793044799},"extras":[{"label":"Fable","window":{"resetsAt":1793044800,"usedPercent":0}}],"capturedAt":\#(captured)}"#
        try? json.write(to: dir.appendingPathComponent("quota.json"), atomically: true, encoding: .utf8)
    }
    let today = ClaudeUsage.dayKey(now)
    try? #"{"version":1,"days":{"\#(today)":{"cost":18.5,"tokens":1280000,"messages":12,"output":9000}}}"#
        .write(to: dir.appendingPathComponent("history.json"), atomically: true, encoding: .utf8)
    writeQuota(five: 3, fiveReset: 1_792_587_600, week: 4, captured: 1_792_569_900)
    let u = ClaudeUsage.load(from: dir)
    check(u?.quota?.fiveHour?.usedPercent == 3 && u?.quota?.extras.first?.label == "Fable" && u?.day(now)?.tokens == 1_280_000,
          "Widget files read")
    check(ClaudeUsage.summaryLines(u!, now: now).contains { $0.contains("1.3M") }, "Summary shows today's tokens")
    check(ClaudeUsage.until(Date(timeIntervalSince1970: 1_792_587_600), now: now).contains("4"), "Reset countdown")

    var st = ClaudeUsageAlertState()
    check(ClaudeUsage.evaluate(u!, now: now, state: &st).isEmpty, "Low usage: no alert")
    writeQuota(five: 72, fiveReset: 1_792_587_600, week: 4, captured: 1_792_569_900)
    var alerts = ClaudeUsage.evaluate(ClaudeUsage.load(from: dir)!, now: now, state: &st)
    check(alerts.count == 1 && { if case .nearLimit("fiveHour", 72, _) = alerts[0] { return true }; return false }(), "70 % alert (\(alerts))")
    check(ClaudeUsage.evaluate(ClaudeUsage.load(from: dir)!, now: now, state: &st).isEmpty, "70 % alert only once per window")
    writeQuota(five: 93, fiveReset: 1_792_587_600, week: 4, captured: 1_792_569_900)
    alerts = ClaudeUsage.evaluate(ClaudeUsage.load(from: dir)!, now: now, state: &st)
    check(alerts.count == 1 && ClaudeUsage.message(alerts[0], now: now).motion == .surprised, "90 % alert")
    writeQuota(five: 1, fiveReset: 1_792_605_600, week: 4, captured: 1_792_569_900)
    alerts = ClaudeUsage.evaluate(ClaudeUsage.load(from: dir)!, now: now, state: &st)
    check(alerts == [.refilled], "New window after a used-up one: limit back (\(alerts))")
    writeQuota(five: 95, fiveReset: 1_792_605_600, week: 4, captured: 1_792_560_000)
    check(ClaudeUsage.evaluate(ClaudeUsage.load(from: dir)!, now: now, state: &st).isEmpty, "Out-of-date data: no alert")
    try? FileManager.default.removeItem(at: dir)
}

// MARK: Calendar alerts

do {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    func at(_ day: Int, _ h: Int, _ m: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: h, minute: m))! }
    let meeting = CalendarEvent(id: "m", title: "组会", start: at(21, 15, 0), end: at(21, 16, 0), allDay: false, location: "B302")
    let holiday = CalendarEvent(id: "h", title: "休假", start: at(21, 0, 0), end: at(22, 0, 0), allDay: true, location: nil)
    let early = CalendarEvent(id: "e", title: "早会", start: at(21, 9, 0), end: at(21, 9, 30), allDay: false, location: nil)
    let tomorrow = CalendarEvent(id: "t", title: "答辩", start: at(22, 10, 0), end: at(22, 11, 0), allDay: false, location: nil)
    let events = [tomorrow, meeting, holiday, early]
    var st = CalendarAlertState()

    var alerts = CalendarAlerts.evaluate(events, now: at(21, 5, 30), leadMinutes: 10, present: true, state: &st, calendar: cal)
    check(alerts.isEmpty, "No overview before 06:00")
    alerts = CalendarAlerts.evaluate(events, now: at(21, 10, 0), leadMinutes: 10, present: false, state: &st, calendar: cal)
    check(alerts.isEmpty, "Overview waits for the owner")
    alerts = CalendarAlerts.evaluate(events, now: at(21, 10, 0), leadMinutes: 10, present: true, state: &st, calendar: cal)
    check(alerts == [.today([holiday, meeting])], "Overview: all-day first, ended events left out")
    check(CalendarAlerts.evaluate(events, now: at(21, 10, 1), leadMinutes: 10, present: true, state: &st, calendar: cal).isEmpty,
          "Overview once per day")
    check(CalendarAlerts.evaluate(events, now: at(21, 14, 49), leadMinutes: 10, present: true, state: &st, calendar: cal).isEmpty,
          "Not yet within the lead time")
    alerts = CalendarAlerts.evaluate(events, now: at(21, 14, 50), leadMinutes: 10, present: false, state: &st, calendar: cal)
    check(alerts == [.upcoming(meeting, minutes: 10)], "Event alert at the lead time, also while away")
    check(CalendarAlerts.evaluate(events, now: at(21, 14, 55), leadMinutes: 10, present: true, state: &st, calendar: cal).isEmpty,
          "Event alert once")
    var moved = meeting
    moved.start = at(21, 15, 30)
    alerts = CalendarAlerts.evaluate([moved], now: at(21, 15, 25), leadMinutes: 10, present: true, state: &st, calendar: cal)
    check(alerts == [.upcoming(moved, minutes: 5)], "A moved event is announced again")
    var woke = CalendarAlertState(lastDigestDay: "2026-10-21")
    alerts = CalendarAlerts.evaluate(events, now: at(21, 15, 3), leadMinutes: 10, present: true, state: &woke, calendar: cal)
    check(alerts == [.upcoming(meeting, minutes: -3)], "Just-started event still announced")
    check(CalendarAlerts.message(alerts[0]).text.contains("已经开始") || CalendarAlerts.message(alerts[0]).text.contains("started"),
          "Started wording")
    check(CalendarAlerts.evaluate(events, now: at(21, 15, 6), leadMinutes: 10, present: true, state: &woke, calendar: cal).isEmpty,
          "No alert later than 5 min after the start")
    check(CalendarAlerts.label(meeting).hasSuffix("组会（B302）") || CalendarAlerts.label(meeting).hasSuffix("组会 (B302)"), "Label with place")
    check(CalendarAlerts.next(events, now: at(21, 12, 0)) == meeting, "Next timed event")
    var online = meeting
    online.location = "https://meeting.dingtalk.com/j/abc"
    check(!CalendarAlerts.label(online).contains("http"), "Meeting links are not shown as places")
    let line = CalendarAlerts.contextLine(events, now: at(21, 12, 0), calendar: cal) ?? ""
    check(line.contains("组会") && line.contains("休假") && !line.contains("早会") && line.contains("明天日程") && line.contains("答辩"),
          "Context line (\(line))")
    check(CalendarAlerts.contextLine([], now: at(21, 12, 0), calendar: cal) == "主人日历：今明两天没有日程", "Empty context line")
}

// MARK: DeepSeek balance

do {
    check(DeepSeekBalance.endpoint(baseURL: "https://api.deepseek.com/v1")?.absoluteString == "https://api.deepseek.com/user/balance",
          "Balance endpoint from the base URL")
    check(DeepSeekBalance.endpoint(baseURL: "https://api.openai.com/v1") == nil, "No balance endpoint for other providers")
    let body = #"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"110.00","granted_balance":"10.00","topped_up_balance":"100.00"}]}"#
    let b = DeepSeekBalance.parse(Data(body.utf8))
    check(b?.available == true && b?.accounts.first?.total == 110 && b?.accounts.first?.granted == 10, "Balance parsing")
    check(b?.short == "¥110.00" && b?.isLow == false, "Balance text (\(b?.short ?? ""))")
    var st = DeepSeekBalanceAlertState()
    check(DeepSeekBalanceAlerts.evaluate(b!, state: &st) == nil, "No warning with ¥110")
    var low = b!
    low.accounts[0].total = 6.5
    check(DeepSeekBalanceAlerts.evaluate(low, state: &st) != nil, "Warning below ¥10")
    check(DeepSeekBalanceAlerts.evaluate(low, state: &st) == nil, "Warning once")
    _ = DeepSeekBalanceAlerts.evaluate(b!, state: &st)
    check(DeepSeekBalanceAlerts.evaluate(low, state: &st) != nil, "Warning again after a top-up")
    check(DeepSeekBalance.parse(Data("{}".utf8)) == nil, "Malformed balance refused")
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

// MARK: Desktop film: desktop in view

do {
    let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    check(DesktopView.coverage(of: screen, by: []) == 0, "No windows, nothing covered")
    check(DesktopView.coverage(of: screen, by: [screen]) == 1, "A full-screen window covers everything")
    let half = DesktopView.coverage(of: screen, by: [CGRect(x: 0, y: 0, width: 800, height: 1000)])
    check(abs(half - 0.5) < 0.001, "Half the screen covered (\(half))")
    let overlap = DesktopView.coverage(of: screen, by: [CGRect(x: 0, y: 0, width: 800, height: 1000), CGRect(x: 400, y: 0, width: 400, height: 1000)])
    check(abs(overlap - 0.5) < 0.001, "Overlapping windows count once (\(overlap))")
    let other = DesktopView.coverage(of: screen, by: [CGRect(x: 1600, y: 0, width: 1600, height: 1000)])
    check(other == 0, "A window on another screen does not count")

    var t = DesktopViewTracker(samples: 2)
    check(!t.update(coverage: 0.05), "One reading does not start the film")
    check(t.update(coverage: 0.05), "Two readings in a row start it")
    check(t.update(coverage: 0.25), "Between the thresholds the state is kept")
    check(t.update(coverage: 0.8) && !t.update(coverage: 0.8), "Covering needs two readings as well")
    _ = t.update(coverage: 0); _ = t.update(coverage: 0)
    check(t.inView && !t.update(coverage: 0, allowed: false), "Not allowed: off at once")
    check(!t.update(coverage: 0.05) && t.update(coverage: 0.05), "Allowed again: two readings")
    var u = DesktopViewTracker(samples: 2)
    _ = u.update(coverage: 0.05); _ = u.update(coverage: 0.9)
    check(!u.update(coverage: 0.05), "An interrupted streak starts over")
}

// MARK: Desktop icons

do {
    let parsed = DesktopItems.parse("48\n1410\t75\t报告 v2.pdf\n1410\t175\t截屏2026-10-27 19.02.11.png\nbroken line\n1310\t75\t\tTabbed")
    check(parsed.iconSize == 48 && parsed.items.count == 3, "Finder output: size and items (\(parsed.items.count))")
    check(parsed.items[0] == DesktopItems.Item(name: "报告 v2.pdf", center: CGPoint(x: 1410, y: 75)), "Finder output: names with spaces")
    check(parsed.items[2].name == "\tTabbed", "Finder output: a tab inside a name is kept")
    check(DesktopItems.parse("").iconSize == 64 && DesktopItems.parse("x\n").items.isEmpty, "Finder output: defaults")
    check(DesktopItems.parse("64\n-1\t-1\tPPT汇总\n-1\t20\tLeft").items.map(\.name) == ["Left"], "Finder output: items without a place")
    let frame = DesktopItems.pictureFrame(of: parsed.items[0], iconSize: 48, mainScreenHeight: 956)
    check(frame == CGRect(x: 1386, y: 857, width: 48, height: 48), "Picture frame in screen coordinates (\(frame))")
    let fresh = DesktopItems.newcomers(before: ["报告 v2.pdf"], now: parsed.items)
    check(fresh.map(\.name) == ["截屏2026-10-27 19.02.11.png", "\tTabbed"], "Newcomers keep Finder's order")
    check(DesktopItems.kind(of: "截屏2026-10-27 19.02.11.png") == .screenshot && DesktopItems.kind(of: "Screenshot 2026.png") == .screenshot,
          "Screenshots by name")
    check(DesktopItems.kind(of: "a.PDF") == .pdf && DesktopItems.kind(of: "Setup.dmg") == .installer && DesktopItems.kind(of: "照片") == .folder,
          "Kinds by extension")
    check(DesktopItems.quoted("一个名字特别特别特别特别长的文件夹名称.pdf").count <= 20, "Long names are shortened")
    check(DesktopItems.remark(onArrival: "a.pdf").contains("PDF") || DesktopItems.remark(onArrival: "a.pdf").contains("a.pdf"),
          "Arrival remark names the kind")
    check(DesktopItems.widgetKind(owner: "Claude 用量", name: "") == .claude && DesktopItems.widgetKind(owner: "GitHub 热力图", name: "") == .github
          && DesktopItems.widgetKind(owner: "通知中心", name: "每日天气预报") == .weather && DesktopItems.widgetKind(owner: "通知中心", name: "仓位列表") == .stocks
          && DesktopItems.widgetKind(owner: "通知中心", name: "") == .other, "Widget kinds by owner and title")
    let usage = DesktopItems.remark(widgetOwner: "Claude 用量", name: "", claudePercent: 87)
    check(usage.contains("87"), "Claude widget remark tells the usage (\(usage))")
    check(!DesktopItems.remark(widgetOwner: "通知中心", name: "").contains("通知中心"), "No owner name for the system's own widgets")
}

// MARK: Speech

do {
    func spoken(_ s: String) -> String { SpeechText.clean(s) }
    check(spoken("你好呀～今天也要加油！🌸") == "你好呀，今天也要加油！", "Speech: tilde becomes a pause, emoji go (\(spoken("你好呀～今天也要加油！🌸")))")
    check(spoken("🗑 已忘掉 2 条关于“咖啡”的记忆") == "已忘掉 2 条关于“咖啡”的记忆。", "Speech: text-style emoji go (\(spoken("🗑 已忘掉 2 条关于“咖啡”的记忆")))")
    check(spoken("嘿嘿 (｡･ω･｡) 被摸头了 (^▽^)") == "嘿嘿 被摸头了。", "Speech: kaomoji go (\(spoken("嘿嘿 (｡･ω･｡) 被摸头了 (^▽^)")))")
    check(spoken("（笑）去看 Nature (2024)") == "（笑）去看 Nature (2024)。", "Speech: words in brackets stay (\(spoken("（笑）去看 Nature (2024)")))")
    let md = "## 结论\n- **能量**守恒：$E = mc^2$\n\n```python\nprint(1)\n```\n| a | b |\n|---|---|\n详见 [论文](https://arxiv.org/abs/1) 与 https://x.org/y 。"
    check(spoken(md) == "结论。能量守恒。详见 论文 与。", "Speech: Markdown, code, formulas, tables and links (\(spoken(md)))")
    check(spoken("余额低于 $1.50，或 $2 以下") == "余额低于 $1.50，或 $2 以下。", "Speech: prices are not formulas (\(spoken("余额低于 $1.50，或 $2 以下")))")
    check(spoken("每 15–30 分钟 → 去走走") == "每 15到30 分钟，去走走。", "Speech: ranges and arrows in words (\(spoken("每 15–30 分钟 → 去走走")))")
    check(spoken("Rarely (every 15–30 min)") == "Rarely (every 15 to 30 min).", "Speech: English ranges (\(spoken("Rarely (every 15–30 min)")))")
    check(spoken("1. 第一步\n2) 第二步\n3.5 秒后") == "第一步。第二步。3.5 秒后。", "Speech: list numbers go, decimals stay (\(spoken("1. 第一步\n2) 第二步\n3.5 秒后")))")
    check(spoken("🌸✨") == "" && spoken("```\ncode\n```") == "" && spoken("～～") == "", "Speech: nothing to say")
    check(spoken("Hello , world\nBye") == "Hello, world. Bye.", "Speech: English lines (\(spoken("Hello , world\nBye")))")

    let long = String(repeating: "这是一句话。", count: 20)
    let cut = SpeechText.excerpt(long, limit: 40)
    check(cut.truncated && cut.text.hasSuffix("。") && cut.text.count <= 40 && cut.text.count >= 36, "Speech excerpt ends a sentence (\(cut.text.count))")
    let hard = SpeechText.excerpt(String(repeating: "长", count: 100), limit: 30)
    check(hard.truncated && hard.text.count == 30, "Speech excerpt without sentence ends")
    check(SpeechText.excerpt("短句。", limit: 30) == ("短句。", false), "Speech excerpt of a short text")

    let parts = SpeechText.chunks("嗯！今天的天气真不错，适合出去走走。我们下午三点出发吧？记得带伞……以防万一。")
    check(parts == ["嗯！今天的天气真不错，适合出去走走。", "我们下午三点出发吧？记得带伞……以防万一。"], "Speech chunks: short first piece (\(parts))")
    let commas = SpeechText.chunks(String(repeating: "这是一个没有句号但是有逗号的长句子，", count: 6), first: 40, size: 90)
    check(commas.count >= 2 && commas[0].count <= 40 && commas.dropFirst().allSatisfy { $0.count <= 90 } && commas[0].hasSuffix("，"),
          "Speech chunks: long sentences split after a comma (\(commas.map { $0.count }))")
    check(SpeechText.chunks(String(repeating: "长", count: 100), first: 40, size: 90).map { $0.count } == [40, 60], "Speech chunks: hard split")
    check(SpeechText.chunks("Hello there. How are you? Fine.", first: 15, size: 40) == ["Hello there.", "How are you? Fine."],
          "Speech chunks: English sentences (\(SpeechText.chunks("Hello there. How are you? Fine.", first: 15, size: 40)))")
    check(SpeechText.chunks("“好！”他说。") == ["“好！”他说。"] && SpeechText.chunks("") == [], "Speech chunks: quotes and empty text")
    check(SpeechText.chunks("你好").joined() == "你好", "Speech chunks: text without a sentence end")
    check(SpeechText.language(of: "好的，OK") == "zh-CN" && SpeechText.language(of: "Hello there") == "en-US"
          && SpeechText.language(of: "こんにちは、元気？") == "ja-JP" && SpeechText.language(of: "안녕하세요") == "ko-KR", "Speech language")

    let voices = [
        SpeechVoice(identifier: "com.apple.eloquence.zh-CN.Flo", name: "Flo", language: "zh-CN", quality: 1, female: true),
        SpeechVoice(identifier: "com.apple.voice.compact.zh-CN.Tingting", name: "Tingting", language: "zh-CN", quality: 1, female: true),
        SpeechVoice(identifier: "com.apple.voice.compact.zh-HK.Sinji", name: "Sinji", language: "zh-HK", quality: 1, female: true),
        SpeechVoice(identifier: "com.apple.voice.compact.zh-TW.Meijia", name: "Meijia", language: "zh-TW", quality: 1, female: true),
        SpeechVoice(identifier: "com.apple.speech.synthesis.voice.Albert", name: "Albert", language: "en-US", quality: 1, novelty: true),
        SpeechVoice(identifier: "com.apple.voice.compact.en-US.Samantha", name: "Samantha", language: "en-US", quality: 1, female: true),
        SpeechVoice(identifier: "com.apple.speech.synthesis.voice.Fred", name: "Fred", language: "en-US", quality: 1, female: false),
    ]
    check(SpeechVoices.ranked(voices, for: "zh-CN").map(\.name) == ["Tingting", "Meijia", "Flo"], "Voices: region, no Cantonese, synthetic last")
    check(SpeechVoices.ranked(voices, for: "en-US").map(\.name) == ["Samantha", "Fred"], "Voices: novelty voices left out")
    check(!SpeechVoices.hasNatural(voices, language: "zh-CN"), "Voices: only standard ones installed")
    let premium = voices + [SpeechVoice(identifier: "com.apple.voice.premium.zh-CN.Lilian", name: "Lilian", language: "zh-CN", quality: 3, female: true),
                            SpeechVoice(identifier: "com.apple.voice.enhanced.zh-CN.Tingting", name: "Tingting", language: "zh-CN", quality: 2, female: true)]
    check(SpeechVoices.pick(premium, language: "zh-CN", preferred: "")?.name == "Lilian" && SpeechVoices.hasNatural(premium, language: "zh-CN"),
          "Voices: premium first")
    check(SpeechVoices.pick(premium, language: "zh-CN", preferred: "com.apple.voice.compact.zh-TW.Meijia")?.name == "Meijia",
          "Voices: the owner's choice")
    check(SpeechVoices.pick(premium, language: "en-US", preferred: "com.apple.voice.premium.zh-CN.Lilian")?.name == "Samantha",
          "Voices: a choice in another language is passed over")
    check(SpeechVoices.pick(voices, language: "ja-JP", preferred: "") == nil, "Voices: none for the language")

    check(CloudSpeech.endpoint(baseURL: " https://api.siliconflow.cn/v1/ ")?.absoluteString == "https://api.siliconflow.cn/v1/audio/speech"
          && CloudSpeech.endpoint(baseURL: "http://127.0.0.1:8799/v1/audio/speech")?.absoluteString == "http://127.0.0.1:8799/v1/audio/speech",
          "Cloud speech endpoint")
    check(CloudSpeech.endpoint(baseURL: "") == nil && CloudSpeech.endpoint(baseURL: "api.siliconflow.cn/v1") == nil, "Cloud speech endpoint needs a URL")
    let body = CloudSpeech.body(text: "你好", model: CloudSpeech.siliconFlowModel, voice: CloudSpeech.siliconFlowVoice, speed: 9)
    check(body["input"]?.string == "你好" && body["voice"]?.string == "FunAudioLLM/CosyVoice2-0.5B:diana" && body["speed"]?.double == 4
          && body["response_format"]?.string == "mp3" && body["instructions"] == nil, "Cloud speech body")
    check(CloudSpeech.body(text: "hi", model: "gpt-4o-mini-tts", voice: "coral", speed: 1)["instructions"]?.string?.isEmpty == false,
          "Cloud speech tone for gpt-4o")
    check(CloudSpeech.errorMessage(Data(#"{"error":{"message":"Invalid token"}}"#.utf8), status: 401) == "HTTP 401: Invalid token"
          && CloudSpeech.errorMessage(Data(#"{"message":"余额不足"}"#.utf8), status: 403) == "HTTP 403: 余额不足"
          && CloudSpeech.errorMessage(Data("Invalid token".utf8), status: 401) == "HTTP 401: Invalid token"
          && CloudSpeech.errorMessage(Data("<html><body>Bad gateway</body></html>".utf8), status: 502) == "HTTP 502", "Cloud speech errors")

    check(CloudSpeechBalance.endpoint(baseURL: CloudSpeech.siliconFlowURL)?.absoluteString == "https://api.siliconflow.cn/v1/user/info"
          && CloudSpeechBalance.endpoint(baseURL: "https://api.siliconflow.com/v1/audio/speech")?.absoluteString == "https://api.siliconflow.com/v1/user/info",
          "Speech balance endpoint")
    check(CloudSpeechBalance.endpoint(baseURL: "https://api.openai.com/v1") == nil && CloudSpeechBalance.endpoint(baseURL: "") == nil,
          "No speech balance for other services")
    check(CloudSpeechBalance.currency(baseURL: CloudSpeech.siliconFlowURL) == "CNY" && CloudSpeechBalance.currency(baseURL: "https://api.siliconflow.com/v1") == "USD"
          && CloudSpeechBalance.console(baseURL: "https://api.siliconflow.com/v1")?.host == "cloud.siliconflow.com", "Speech balance currency and console")
    let info = #"{"code":20000,"message":"OK","status":true,"data":{"id":"u","isAdmin":false,"balance":"0.88","status":"normal","chargeBalance":"88.00","totalBalance":"88.88"}}"#
    let sb = CloudSpeechBalance.parse(Data(info.utf8), currency: "CNY")
    check(sb?.total == 88.88 && sb?.granted == 0.88 && sb?.toppedUp == 88 && sb?.short == "¥88.88", "Speech balance parsing (\(sb?.short ?? "nil"))")
    check(sb?.detail.contains("¥0.88") == true && sb?.detail.contains("¥88.00") == true, "Speech balance detail (\(sb?.detail ?? "nil"))")
    check(CloudSpeechBalance.parse(Data(#"{"data":{"balance":1.5,"chargeBalance":2}}"#.utf8), currency: "USD")?.short == "$3.50",
          "Speech balance from numbers without a total")
    check(CloudSpeechBalance.parse(Data("Invalid token".utf8), currency: "CNY") == nil
          && CloudSpeechBalance.parse(Data(#"{"code":40001,"data":{"id":"u"}}"#.utf8), currency: "CNY") == nil, "Speech balance absent")
    let invalid = Data(#"{"code":30014,"data":null,"message":"Token is invalid."}"#.utf8)  // SiliconFlow's answer to a wrong key
    check(CloudSpeechBalance.parse(invalid, currency: "CNY") == nil && CloudSpeech.errorMessage(invalid, status: 401) == "HTTP 401: Token is invalid.",
          "Speech balance with a wrong key")
    let gone = Data(#"{"code":20092,"message":"This endpoint is deprecated and is no longer available.","data":null}"#.utf8)
    check(CloudSpeechBalance.retired(gone, status: 410) && CloudSpeechBalance.retired(gone, status: 200) && CloudSpeechBalance.retired(Data(), status: 410)
          && !CloudSpeechBalance.retired(invalid, status: 401) && !CloudSpeechBalance.retired(Data(info.utf8), status: 200), "Retired speech balance endpoint")

    let cacheName = CloudSpeechCache.name(text: "你好", model: CloudSpeech.siliconFlowModel, voice: CloudSpeech.siliconFlowVoice, speed: 1,
                                          baseURL: CloudSpeech.siliconFlowURL)
    check(cacheName.count == 68 && cacheName.hasSuffix(".mp3")
          && cacheName == CloudSpeechCache.name(text: "你好", model: " FunAudioLLM/CosyVoice2-0.5B", voice: CloudSpeech.siliconFlowVoice,
                                                speed: 1.0001, baseURL: "https://API.siliconflow.cn/v1/"), "Voice cache: stable names")
    check(Set([cacheName,
               CloudSpeechCache.name(text: "你好！", model: CloudSpeech.siliconFlowModel, voice: CloudSpeech.siliconFlowVoice, speed: 1, baseURL: CloudSpeech.siliconFlowURL),
               CloudSpeechCache.name(text: "你好", model: CloudSpeech.siliconFlowModel, voice: "FunAudioLLM/CosyVoice2-0.5B:claire", speed: 1, baseURL: CloudSpeech.siliconFlowURL),
               CloudSpeechCache.name(text: "你好", model: CloudSpeech.siliconFlowModel, voice: CloudSpeech.siliconFlowVoice, speed: 1.2, baseURL: CloudSpeech.siliconFlowURL),
               CloudSpeechCache.name(text: "你好", model: CloudSpeech.siliconFlowModel, voice: CloudSpeech.siliconFlowVoice, speed: 1, baseURL: "https://api.openai.com/v1"),
              ]).count == 5, "Voice cache: text, voice, rate and service change the name")
    let day = Date(timeIntervalSince1970: 1_800_000_000)
    let files = (0..<10).map { CloudSpeechCache.File(name: "f\($0)", size: 10, used: day.addingTimeInterval(Double($0))) }
    check(CloudSpeechCache.evictions(files, limit: 100).isEmpty, "Voice cache: nothing to evict within the limit")
    check(CloudSpeechCache.evictions(files.shuffled(), limit: 80) == ["f0", "f1", "f2", "f3"], "Voice cache: least recently used first, down to 80%")
    check(CloudSpeech.isLocal(baseURL: "http://127.0.0.1:8790/v1") && CloudSpeech.isLocal(baseURL: " http://localhost:8000/v1 ")
          && !CloudSpeech.isLocal(baseURL: CloudSpeech.siliconFlowURL) && !CloudSpeech.isLocal(baseURL: ""), "Local speech services")
    check(CloudSpeech.isLocalVoice(baseURL: "http://127.0.0.1:8790/v1") && !CloudSpeech.isLocalVoice(baseURL: "http://127.0.0.1:8000/v1")
          && !CloudSpeech.isLocalVoice(baseURL: "https://example.com:8790/v1"), "DeskPet's own local voice")
    var queue = SpeechQueue<Int>(capacity: 2)
    check(queue.push(1).isEmpty && queue.push(2).isEmpty && queue.push(3) == [1], "Speech queue drops the oldest")
    check(queue.pop() == 2 && queue.removeAll() == [3] && queue.pop() == nil && queue.isEmpty, "Speech queue order and clearing")
}

// MARK: Music detection

do {
    check(SoundSource.of(bundleID: "com.apple.Music") == .music && SoundSource.of(bundleID: "com.netease.163music") == .music
          && SoundSource.of(bundleID: "com.tencent.QQMusicMac") == .music && SoundSource.of(bundleID: "com.spotify.client") == .music,
          "Music players count as music")
    check(SoundSource.of(bundleID: "com.tencent.xinWeChat") == .ignored && SoundSource.of(bundleID: "com.tencent.qq") == .ignored
          && SoundSource.of(bundleID: "com.alibaba.DingTalkMac") == .ignored && SoundSource.of(bundleID: "com.tencent.meeting") == .ignored,
          "Chats and calls never count")
    check(SoundSource.of(bundleID: "com.colliderli.iina") == .ignored && SoundSource.of(bundleID: "com.youku.mac") == .ignored
          && SoundSource.of(bundleID: "com.apple.QuickTimePlayerX") == .ignored && SoundSource.of(bundleID: "com.apple.TV") == .ignored,
          "Video players never count")
    check(SoundSource.of(bundleID: "com.apple.notificationcenterui") == .ignored
          && SoundSource.of(bundleID: "com.apple.audio.SystemSoundServer-OSX") == .ignored, "System sounds never count")
    check(SoundSource.of(bundleID: "com.apple.Safari") == .undecided && SoundSource.of(bundleID: "com.apple.WebKit.GPU") == .undecided
          && SoundSource.of(bundleID: "com.google.Chrome") == .undecided && SoundSource.of(bundleID: nil) == .undecided,
          "Browsers and unknown players are judged by their sound")

    typealias W = MusicJudge.Window
    let song = W(music: 0.7, speech: 0.02), talk = W(music: 0.05, speech: 0.98)
    let narration = W(music: 0.67, speech: 0.97, singing: 0.02), vocals = W(music: 0.55, speech: 0.6, singing: 0.4)
    check(MusicJudge.counts(song) && MusicJudge.counts(vocals) && !MusicJudge.counts(talk) && !MusicJudge.counts(narration)
          && !MusicJudge.counts(W(music: 0.32)), "Music windows: songs and sung vocals, not talk or narration over music")
    var judge = MusicJudge()
    check(!judge.add(song) && !judge.add(song) && judge.add(song), "Music after 3 music windows")
    check(judge.add(talk) && judge.add(talk) && judge.add(talk) && !judge.add(talk), "Music ends after 4 of 5 windows are not music")
    var ding = MusicJudge()
    check(!ding.add(W(music: 0.44)) && !ding.add(W()) && !ding.add(W()) && !ding.add(W()), "A notification sound is not music")
    var video = MusicJudge()
    check([narration, narration, song, narration, narration, narration].allSatisfy { !video.add($0) }, "Narration over music is not music")
    judge.reset()
    check(!judge.isMusic, "Judge reset")
}

// MARK: Reminders as memories, thoughts that decide

do {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 10, minute: 0))!
    var r = Memory(text: "提醒：下午三点开会", kind: .reminder, importance: 10, source: "remind")
    r.followUp = now.addingTimeInterval(3600)
    check(r.pinned && !r.faded(at: now.addingTimeInterval(30 * 86400)), "Reminder: in the background and never fading until given")
    let line = MemoryRecall.line(r, now: now, calendar: cal, label: "R1")
    check(line.contains("R1") && line.contains("【提醒】") && line.contains("11:00") && line.contains("开会"), "Reminder line (\(line))")
    var given = r
    given.followUp = nil
    given.importance = 4
    given.recalls = 1
    given.recalled = now
    check(!given.pinned && MemoryRecall.line(given, now: now, calendar: cal).contains("已提醒")
          && given.faded(at: now.addingTimeInterval(10 * 86400)) && !given.faded(at: now.addingTimeInterval(86400)),
          "Given reminder: out of the background, faded within ten days")
    let rendered = MemoryRecall.render([r, Memory(text: "主人对花粉过敏", kind: .fact, importance: 8)], now: now, calendar: cal)
    check(rendered.hasPrefix("### 主人交代的提醒与日程"), "Reminders come first in the background")

    check(InnerThoughts.dance(#"{"thoughts": [], "dance": true}"#) == true && InnerThoughts.dance(#"{"thoughts": [], "dance": false}"#) == false
          && InnerThoughts.dance(#"{"thoughts": [], "dance": null}"#) == nil && InnerThoughts.dance(#"{"thoughts": []}"#) == nil
          && InnerThoughts.dance("not json") == nil, "Thoughts: whether to sway to the music")
    check(InnerThoughts.parse(#"{"thoughts": [{"thought": "a", "say": "b", "motion": "happy", "motivation": 4, "follow_up": "r1"}], "dance": true}"#)?
          .first?.followUp == "R1", "Thoughts still parse beside dance, reminder labels upper-cased")

    let meeting = CalendarEvent(id: "evt", title: "组会", start: cal.date(bySettingHour: 14, minute: 0, second: 0, of: now)!,
                                end: cal.date(bySettingHour: 15, minute: 30, second: 0, of: now)!, allDay: false, location: "会议室 A")
    let m = CalendarAlerts.reminder(meeting, leadMinutes: 10, calendar: cal)
    check(m.source == "calendar:" + meeting.key && m.text == "日程：10月29日 星期四 14:00–15:30 组会（会议室 A）"
          && m.at == meeting.start.addingTimeInterval(-600), "Calendar event as a reminder (\(m.text))")
    let holiday = CalendarEvent(id: "h", title: "休假", start: cal.startOfDay(for: now), end: cal.startOfDay(for: now).addingTimeInterval(86400),
                                allDay: true, location: nil)
    let h = CalendarAlerts.reminder(holiday, leadMinutes: 10, calendar: cal)
    check(h.text == "日程：10月29日 星期四 全天 休假" && cal.component(.hour, from: h.at) == 8 && cal.component(.minute, from: h.at) == 30,
          "All-day event: given at 08:30 (\(h.text))")
}

// MARK: Reaching for the pointer

do {
    let stage = CGRect(x: 100, y: 0, width: 200, height: 300)
    let zone = PointerTease.zone(stage: stage)
    check(zone == CGRect(x: 130, y: 165, width: 140, height: 255), "Tease zone above the upper body (\(zone))")
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func run(_ tease: inout PointerTease, from: Double, to: Double, at point: (Double) -> CGPoint, allowed: Bool = true) -> [Double] {
        var grabs: [Double] = []
        for i in stride(from: from, to: to, by: 1.0 / 30) {
            if tease.update(pointer: point(i), zone: zone, now: t0.addingTimeInterval(i), allowed: allowed) { grabs.append(i) }
        }
        return grabs
    }
    let wiggle: (Double) -> CGPoint = { CGPoint(x: 200 + 30 * sin($0 * 6), y: 300) }
    var tease = PointerTease()
    let grabs = run(&tease, from: 0, to: 3, at: wiggle)
    // The pointer slows down at the turns of the wiggle (under 2 pt a frame), which do not count: about 1 s in all.
    check(grabs.count == 1 && grabs[0] >= 0.8 && grabs[0] <= 1.2, "Grab after 0.8 s of play above the head (\(grabs))")
    check(run(&tease, from: 3, to: 20, at: wiggle).isEmpty, "No second grab within the cooldown")
    check(run(&tease, from: 26, to: 28, at: wiggle).count == 1, "Another grab after the cooldown")
    var still = PointerTease()
    check(run(&still, from: 0, to: 5, at: { _ in CGPoint(x: 200, y: 300) }).isEmpty, "A still pointer is no play")
    var away = PointerTease()
    check(run(&away, from: 0, to: 5, at: { CGPoint(x: 600 + 30 * sin($0 * 6), y: 300) }).isEmpty, "Play elsewhere does not count")
    var held = PointerTease()
    check(run(&held, from: 0, to: 3, at: wiggle, allowed: false).isEmpty, "Nothing while not allowed (dragged, asleep)")
    var brief = PointerTease()
    _ = run(&brief, from: 0, to: 0.5, at: wiggle)
    _ = run(&brief, from: 0.5, to: 1.0, at: { CGPoint(x: 600 + 30 * sin($0 * 6), y: 300) })
    check(brief.teased < 0.05, "Time outside the zone takes the play back (\(brief.teased))")
}

print(failures == 0 ? "All \(checks) checks passed." : "\(failures) of \(checks) checks failed.")
exit(failures == 0 ? 0 : 1)
