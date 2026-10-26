import Foundation

/// The semantic motions the language model may request. Each Live2D model maps them onto its own
/// motion groups and expressions through `pet-map.json`.
enum PetMotion: String, CaseIterable, Codable {
    case idle, happy, wave, nod, shake, think, surprised, sleepy, shy, eat, sad
}

/// A reminder the model asks to schedule, e.g. "remind me about the meeting in 30 minutes".
struct RemindRequest: Codable, Equatable {
    var minutes: Int
    var text: String
}

/// A calendar event the model asks to add (after the owner confirms it). Times are local, "yyyy-MM-dd HH:mm"
/// (all-day events: "yyyy-MM-dd").
struct EventRequest: Codable, Equatable {
    var title: String
    var start: String
    var end: String?
    var location: String?
    var allDay: Bool = false

    /// Start and end as dates: a missing or earlier end lasts one hour (all-day: the whole start day); nil when
    /// the start cannot be read.
    func interval(calendar: Calendar = .current) -> (start: Date, end: Date)? {
        func parse(_ text: String, _ format: String) -> Date? {
            let f = DateFormatter()
            f.calendar = calendar
            f.timeZone = calendar.timeZone
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = format
            return f.date(from: text.trimmingCharacters(in: .whitespaces))
        }
        if allDay {
            guard let day = parse(String(start.prefix(10)), "yyyy-MM-dd") else { return nil }
            let first = calendar.startOfDay(for: day)
            let last = end.flatMap { parse(String($0.prefix(10)), "yyyy-MM-dd") }.map { calendar.startOfDay(for: $0) } ?? first
            guard let after = calendar.date(byAdding: .day, value: 1, to: max(first, last)) else { return nil }
            return (first, after)
        }
        guard let from = parse(start, "yyyy-MM-dd HH:mm") else { return nil }
        let to = end.flatMap { parse($0, "yyyy-MM-dd HH:mm") }.flatMap { $0 > from ? $0 : nil } ?? from.addingTimeInterval(3600)
        return (from, to)
    }
}

/// Development work the model hands to Claude Code: the task in full and the project folder (nil: the default).
struct ClaudeTaskRequest: Codable, Equatable {
    var task: String
    var dir: String?

    /// The shell command that starts an interactive Claude Code session on the task in `dir`: every part single-quoted.
    func shellCommand(claude: String, dir: String) -> String {
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        return "cd \(q(dir)) && \(q(claude)) \(q(task))"
    }
}

/// The structured reply of the pet persona.
struct PetReply: Codable, Equatable {
    var reply: String
    var motion: PetMotion
    var remind: RemindRequest?
    /// A city whose weather the pet wants before answering (not in its context yet).
    var weatherCity: String?
    /// Something worth keeping in the memory bank (one short sentence about the owner), or nil.
    var remember: String?
    /// A keyword: memories containing it are to be forgotten, or nil.
    var forget: String?
    /// An application to open, by name (e.g. "微信", "Safari"), or nil.
    var openApp: String? = nil
    /// A calendar event to add (after the owner confirms), or nil.
    var addEvent: EventRequest? = nil
    /// A task for the executing agent (files, commands, multi-step work), in the owner's words, or nil.
    var agentTask: String? = nil
    /// Development work for Claude Code, opened in Terminal for the owner to follow, or nil.
    var claudeTask: ClaudeTaskRequest? = nil
    /// true: keep the Mac running with the lid closed; false: let it sleep again; nil: no change.
    var lidAwake: Bool? = nil

    /// JSON Schema for structured outputs. Every object sets `additionalProperties: false`,
    /// and numerical constraints are omitted because structured outputs do not support them.
    static var schema: JSON {
        [
            "type": "object",
            "additionalProperties": false,
            "required": ["reply", "motion", "remind", "weather_city", "remember", "forget", "open_app", "add_event", "agent_task",
                         "claude_task", "lid_awake"],
            "properties": [
                "reply": ["type": "string", "description": "What the pet says, at most about 60 characters."],
                "motion": ["type": "string", "enum": .array(PetMotion.allCases.map { .string($0.rawValue) })],
                "remind": [
                    "anyOf": [
                        ["type": "null"],
                        [
                            "type": "object",
                            "additionalProperties": false,
                            "required": ["minutes", "text"],
                            "properties": [
                                "minutes": ["type": "integer", "description": "Minutes from now."],
                                "text": ["type": "string"],
                            ],
                        ],
                    ],
                ],
                "weather_city": [
                    "anyOf": [["type": "null"], ["type": "string"]],
                    "description": "City to look up the weather for before answering; null otherwise.",
                ],
                "remember": [
                    "anyOf": [["type": "null"], ["type": "string"]],
                    "description": "A new long-term fact about the owner, as one short sentence; null otherwise.",
                ],
                "forget": [
                    "anyOf": [["type": "null"], ["type": "string"]],
                    "description": "Keyword of memories the owner asked to forget; null otherwise.",
                ],
                "open_app": [
                    "anyOf": [["type": "null"], ["type": "string"]],
                    "description": "Name of an application the owner asked to open; null otherwise.",
                ],
                "add_event": [
                    "anyOf": [
                        ["type": "null"],
                        [
                            "type": "object",
                            "additionalProperties": false,
                            "required": ["title", "start", "end", "location", "all_day"],
                            "properties": [
                                "title": ["type": "string"],
                                "start": ["type": "string", "description": "Local time, yyyy-MM-dd HH:mm (all-day: yyyy-MM-dd)."],
                                "end": ["anyOf": [["type": "null"], ["type": "string"]]],
                                "location": ["anyOf": [["type": "null"], ["type": "string"]]],
                                "all_day": ["type": "boolean"],
                            ],
                        ],
                    ],
                ],
                "agent_task": [
                    "anyOf": [["type": "null"], ["type": "string"]],
                    "description": "A task for the executing agent (files, commands, multi-step work on the Mac); null otherwise.",
                ],
                "claude_task": [
                    "anyOf": [
                        ["type": "null"],
                        [
                            "type": "object",
                            "additionalProperties": false,
                            "required": ["task", "dir"],
                            "properties": [
                                "task": ["type": "string", "description": "The development task for Claude Code, complete."],
                                "dir": ["anyOf": [["type": "null"], ["type": "string"]], "description": "Project folder; null: the default."],
                            ],
                        ],
                    ],
                ],
                "lid_awake": [
                    "anyOf": [["type": "null"], ["type": "boolean"]],
                    "description": "true: keep the Mac running with the lid closed; false: let it sleep again; null: no change.",
                ],
            ],
        ]
    }

    /// Parses model output tolerantly. Accepts bare JSON, JSON inside a Markdown code fence or
    /// surrounded by prose, and unknown motion names; falls back to the whole text with `idle`.
    static func parse(_ raw: String) -> PetReply {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for candidate in jsonCandidates(in: text) {
            guard let json = try? JSON.parse(candidate), let reply = json["reply"]?.string else { continue }
            let motion = json["motion"]?.string.flatMap { PetMotion(rawValue: $0.lowercased()) } ?? .idle
            var remind: RemindRequest?
            if let r = json["remind"], let minutes = r["minutes"]?.int, minutes > 0, let note = r["text"]?.string {
                remind = RemindRequest(minutes: minutes, text: note)
            }
            func text(_ key: String) -> String? {
                let value = json[key]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
                return value?.isEmpty == false ? value : nil
            }
            var event: EventRequest?
            if let e = json["add_event"], let title = e["title"]?.string, let start = e["start"]?.string, !start.isEmpty {
                func field(_ key: String) -> String? {
                    let v = e[key]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
                    return v?.isEmpty == false ? v : nil
                }
                event = EventRequest(title: title, start: start, end: field("end"), location: field("location"),
                                     allDay: e["all_day"]?.bool ?? false)
            }
            var claude: ClaudeTaskRequest?
            if let c = json["claude_task"], let task = c["task"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !task.isEmpty {
                let dir = c["dir"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
                claude = ClaudeTaskRequest(task: task, dir: dir?.isEmpty == false ? dir : nil)
            }
            return PetReply(reply: reply, motion: motion, remind: remind, weatherCity: text("weather_city"),
                            remember: text("remember"), forget: text("forget"), openApp: text("open_app"), addEvent: event,
                            agentTask: text("agent_task"), claudeTask: claude, lidAwake: json["lid_awake"]?.bool)
        }
        return PetReply(reply: text.isEmpty ? "……" : text, motion: .idle, remind: nil)
    }

    private static func jsonCandidates(in text: String) -> [String] {
        var result = [text]
        if let fenceStart = text.range(of: "```") {
            var body = text[fenceStart.upperBound...]
            if let newline = body.firstIndex(of: "\n") { body = body[body.index(after: newline)...] }
            if let fenceEnd = body.range(of: "```") { result.append(String(body[..<fenceEnd.lowerBound])) }
        }
        if let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close {
            result.append(String(text[open...close]))
        }
        return result
    }
}
