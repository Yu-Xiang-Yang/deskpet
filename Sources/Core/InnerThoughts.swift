import Foundation

/// What the model makes of a stretch of conversation (memory consolidation): episodes worth keeping, new lasting
/// facts, corrections of memories already kept (mem0's update and delete), and at most one impression of the owner.
struct MemoryDigest: Equatable {
    struct Episode: Equatable {
        var text: String
        var importance: Int
        /// When to ask how it went, and what about.
        var followUp: Date?
        var followUpNote: String?
    }

    struct Fact: Equatable {
        var text: String
        var importance: Int
    }

    /// A memory shown to the model under `label` ("F1", "E2"): reworded, or deleted when `text` is nil.
    struct Update: Equatable {
        var label: String
        var text: String?
    }

    var episodes: [Episode] = []
    var facts: [Fact] = []
    var updates: [Update] = []
    var insight: Fact?

    var isEmpty: Bool { episodes.isEmpty && facts.isEmpty && updates.isEmpty && insight == nil }

    static var schema: JSON {
        let nullableString: JSON = ["anyOf": [["type": "null"], ["type": "string"]]]
        let fact: JSON = [
            "type": "object", "additionalProperties": false, "required": ["text", "importance"],
            "properties": ["text": ["type": "string"], "importance": ["type": "integer", "description": "1–10."]],
        ]
        return [
            "type": "object",
            "additionalProperties": false,
            "required": ["episodes", "facts", "updates", "insight"],
            "properties": [
                "episodes": [
                    "type": "array",
                    "items": [
                        "type": "object", "additionalProperties": false,
                        "required": ["text", "importance", "follow_up_at", "follow_up"],
                        "properties": [
                            "text": ["type": "string"],
                            "importance": ["type": "integer", "description": "1–10."],
                            "follow_up_at": ["anyOf": [["type": "null"], ["type": "string"]], "description": "yyyy-MM-dd HH:mm, local time."],
                            "follow_up": nullableString,
                        ],
                    ],
                ],
                "facts": ["type": "array", "items": fact],
                "updates": [
                    "type": "array",
                    "items": [
                        "type": "object", "additionalProperties": false, "required": ["id", "text"],
                        "properties": ["id": ["type": "string"], "text": nullableString],
                    ],
                ],
                "insight": ["anyOf": [["type": "null"], fact]],
            ],
        ]
    }

    /// "yyyy-MM-dd HH:mm" (or a bare date, read as 19:00) in the calendar's time zone.
    static func parseTime(_ text: String, calendar: Calendar) -> Date? {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        let t = text.trimmingCharacters(in: .whitespaces)
        f.dateFormat = "yyyy-MM-dd HH:mm"
        if let date = f.date(from: String(t.prefix(16))) { return date }
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: String(t.prefix(10))).flatMap { calendar.date(bySettingHour: 19, minute: 0, second: 0, of: $0) }
    }

    /// Parses the model's output tolerantly (as `PetReply.parse`); nil when no digest can be read. Importance is
    /// clamped to 1–10 (5 when missing); a follow-up more than a day in the past or over 30 days ahead is dropped, one
    /// slightly in the past moves to 30 minutes from now.
    static func parse(_ raw: String, now: Date, calendar: Calendar = .current) -> MemoryDigest? {
        func importance(_ j: JSON?) -> Int { max(1, min(10, j?.int ?? 5)) }
        func text(_ j: JSON?) -> String? {
            let s = j?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
            return s?.isEmpty == false ? s : nil
        }
        for candidate in PetReply.jsonCandidates(in: raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
            guard let json = try? JSON.parse(candidate), json.object != nil,
                  json["episodes"] != nil || json["facts"] != nil || json["updates"] != nil else { continue }
            var digest = MemoryDigest()
            for e in json["episodes"]?.array ?? [] {
                guard let t = text(e["text"]), t.count >= 4 else { continue }
                var episode = Episode(text: t, importance: importance(e["importance"]))
                if let at = text(e["follow_up_at"]).flatMap({ parseTime($0, calendar: calendar) }),
                   at > now.addingTimeInterval(-86400), at < now.addingTimeInterval(30 * 86400) {
                    episode.followUp = max(at, now.addingTimeInterval(1800))
                    episode.followUpNote = text(e["follow_up"])
                }
                digest.episodes.append(episode)
            }
            for f in json["facts"]?.array ?? [] {
                if let t = text(f["text"]), t.count >= 2 { digest.facts.append(Fact(text: t, importance: importance(f["importance"]))) }
            }
            for u in json["updates"]?.array ?? [] {
                if let label = text(u["id"]) { digest.updates.append(Update(label: label.uppercased(), text: text(u["text"]))) }
            }
            if let i = json["insight"], let t = text(i["text"]) { digest.insight = Fact(text: t, importance: importance(i["importance"])) }
            digest.episodes = Array(digest.episodes.prefix(6))
            digest.facts = Array(digest.facts.prefix(6))
            digest.updates = Array(digest.updates.prefix(12))
            return digest
        }
        return nil
    }
}

/// One of the pet's inner thoughts (Liu et al., "Proactive Conversational Agents with Inner Thoughts", CHI 2025):
/// between conversations the pet forms a few thoughts and rates its urge to voice each one now.
struct InnerThought: Equatable {
    var thought: String
    /// What the pet would say.
    var say: String
    var motion: PetMotion
    /// 1–5: the urge to say it now.
    var motivation: Double
    /// Label of the episode it follows up ("E1"), or nil.
    var followUp: String?
}

enum InnerThoughts {
    static var schema: JSON {
        [
            "type": "object",
            "additionalProperties": false,
            "required": ["thoughts"],
            "properties": [
                "thoughts": [
                    "type": "array",
                    "items": [
                        "type": "object", "additionalProperties": false,
                        "required": ["thought", "say", "motion", "motivation", "follow_up"],
                        "properties": [
                            "thought": ["type": "string", "description": "The inner thought, not said aloud."],
                            "say": ["type": "string", "description": "What the pet would say, at most about 40 characters."],
                            "motion": ["type": "string", "enum": .array(PetMotion.allCases.map { .string($0.rawValue) })],
                            "motivation": ["type": "number", "description": "1–5: the urge to say it now."],
                            "follow_up": ["anyOf": [["type": "null"], ["type": "string"]], "description": "Label of the episode followed up, e.g. E1."],
                        ],
                    ],
                ],
            ],
        ]
    }

    /// Parses the thoughts tolerantly; nil when the output holds none. Motivation is clamped to 1–5.
    static func parse(_ raw: String) -> [InnerThought]? {
        for candidate in PetReply.jsonCandidates(in: raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
            guard let list = (try? JSON.parse(candidate))?["thoughts"]?.array else { continue }
            return list.compactMap { t in
                let thought = t["thought"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let say = t["say"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !thought.isEmpty || !say.isEmpty else { return nil }
                let follow = t["follow_up"]?.string?.trimmingCharacters(in: .whitespaces).uppercased()
                return InnerThought(thought: thought, say: say,
                                    motion: t["motion"]?.string.flatMap { PetMotion(rawValue: $0.lowercased()) } ?? .idle,
                                    motivation: max(1, min(5, t["motivation"]?.double ?? 1)),
                                    followUp: follow?.isEmpty == false ? follow : nil)
            }
        }
        return nil
    }

    /// The urge needed to speak: the talkativeness setting's base, half a point higher for each of the last remarks
    /// the owner left unanswered (up to three; someone who is ignored talks less), at most 5.
    static func threshold(base: Double, unanswered: Int) -> Double {
        min(5, base + 0.5 * Double(max(0, min(unanswered, 3))))
    }

    /// How alike two remarks are, 0…1 (cosine of their terms), for leaving out repetitions.
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = MemoryRecall.terms(a), y = MemoryRecall.terms(b)
        let dot = x.reduce(0.0) { $0 + $1.value * (y[$1.key] ?? 0) }
        let nx = sqrt(x.values.reduce(0) { $0 + $1 * $1 }), ny = sqrt(y.values.reduce(0) { $0 + $1 * $1 })
        return nx > 0 && ny > 0 ? dot / (nx * ny) : 0
    }

    /// Why the pet stays silent.
    enum Silence: String, Equatable {
        /// No thought reached the threshold.
        case weak
        /// The strongest thoughts repeat something said recently.
        case repeated
        /// Nothing to say at all.
        case empty
    }

    /// The thought to voice: the strongest at or above `threshold` whose line does not repeat one of `recent`
    /// (similarity 0.6 or more); otherwise why the pet keeps it to itself.
    static func choose(_ thoughts: [InnerThought], threshold: Double, recent: [String]) -> Result<InnerThought, SilenceError> {
        let sayable = thoughts.filter { !$0.say.isEmpty }
        guard !sayable.isEmpty else { return .failure(SilenceError(reason: .empty)) }
        let strong = sayable.filter { $0.motivation >= threshold }.sorted { $0.motivation > $1.motivation }
        guard !strong.isEmpty else { return .failure(SilenceError(reason: .weak)) }
        guard let fresh = strong.first(where: { t in !recent.contains { similarity($0, t.say) >= 0.6 } }) else {
            return .failure(SilenceError(reason: .repeated))
        }
        return .success(fresh)
    }

    struct SilenceError: Error, Equatable {
        var reason: Silence
    }
}
