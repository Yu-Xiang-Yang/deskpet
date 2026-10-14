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

    /// JSON Schema for structured outputs. Every object sets `additionalProperties: false`,
    /// and numerical constraints are omitted because structured outputs do not support them.
    static var schema: JSON {
        [
            "type": "object",
            "additionalProperties": false,
            "required": ["reply", "motion", "remind", "weather_city", "remember", "forget"],
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
            return PetReply(reply: reply, motion: motion, remind: remind, weatherCity: text("weather_city"),
                            remember: text("remember"), forget: text("forget"))
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
