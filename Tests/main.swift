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

print(failures == 0 ? "All \(checks) checks passed." : "\(failures) of \(checks) checks failed.")
exit(failures == 0 ? 0 : 1)
