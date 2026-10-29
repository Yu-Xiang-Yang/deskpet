import Foundation

/// A feeling the model names for a moment (after a reply or a round of thoughts), placed on Russell's circumplex of
/// valence (unpleasant … pleasant) and arousal (drowsy … excited).
enum Feeling: String, CaseIterable, Codable {
    case happy, excited, content, calm, curious, embarrassed, worried, annoyed, lonely, sad, tired

    /// Valence (−1…1) and arousal (0…1) the feeling pulls the mood toward.
    var target: (valence: Double, arousal: Double) {
        switch self {
        case .happy: return (0.7, 0.6)
        case .excited: return (0.7, 0.85)
        case .content: return (0.5, 0.3)
        case .calm: return (0.15, 0.35)
        case .curious: return (0.35, 0.65)
        case .embarrassed: return (-0.2, 0.55)
        case .worried: return (-0.35, 0.65)
        case .annoyed: return (-0.5, 0.7)
        case .lonely: return (-0.4, 0.3)
        case .sad: return (-0.6, 0.25)
        case .tired: return (0.0, 0.1)
        }
    }

    var word: String {
        switch self {
        case .happy: return "开心"
        case .excited: return "兴奋"
        case .content: return "安心"
        case .calm: return "平静"
        case .curious: return "好奇"
        case .embarrassed: return "不好意思"
        case .worried: return "担心"
        case .annoyed: return "不满"
        case .lonely: return "失落"
        case .sad: return "难过"
        case .tired: return "困倦"
        }
    }

    /// "happy（开心）, excited（兴奋）, …", for prompts.
    static var promptList: String { allCases.map { "\($0.rawValue)（\($0.word)）" }.joined(separator: ", ") }

    /// The JSON Schema of a reported feeling: {"feeling", "because"} or null.
    static var schema: JSON {
        ["anyOf": [
            ["type": "null"],
            [
                "type": "object", "additionalProperties": false, "required": ["feeling", "because"],
                "properties": [
                    "feeling": ["type": "string", "enum": .array(allCases.map { .string($0.rawValue) })],
                    "because": ["type": "string", "description": "What caused it, a few words."],
                ],
            ],
        ], "description": "How the moment changed the pet's mood; null when it did not."]
    }
}

/// A feeling reported by the model, and what caused it.
struct FeelingReport: Codable, Equatable {
    var feeling: Feeling
    var because: String

    /// The "mood" field of a reply or of thoughts; nil when absent, null or unknown.
    static func parse(_ json: JSON?) -> FeelingReport? {
        guard let name = json?["feeling"]?.string?.trimmingCharacters(in: .whitespaces).lowercased(),
              let feeling = Feeling(rawValue: name) else { return nil }
        let because = json?["because"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return FeelingReport(feeling: feeling, because: because)
    }
}

/// The pet's mood, carried from moment to moment (after Russell's circumplex model of affect): valence and arousal that
/// events move and that return to a resting state with a half-life of 45 minutes, so that a pat or an unanswered
/// remark colours the next few remarks and is gone after a few hours. Resting arousal is lower at night.
/// What moved the mood lately is kept, for the prompts and Settings → Memory.
struct Affect: Codable, Equatable {
    struct Cause: Codable, Equatable {
        var date: Date
        /// Written with "主人" for the owner, as the prompts are.
        var text: String
    }

    /// −1 (unpleasant) … 1 (pleasant).
    var valence: Double
    /// 0 (drowsy) … 1 (excited).
    var arousal: Double
    /// When the values above were current.
    var updated: Date
    /// What moved the mood, newest first: at most `maxCauses`, none older than `causeHours`.
    var causes: [Cause] = []
    /// The feeling the model named last, and when: it names the mood while it is recent.
    var feeling: Feeling?
    var felt: Date?

    static let restValence = 0.2
    static let halfLife: TimeInterval = 45 * 60
    static let maxCauses = 5
    static let causeHours = 3.0
    /// How long a feeling the model named gives the mood its name.
    static let feelingMinutes = 40.0
    /// How far a named feeling pulls the mood toward its place.
    static let feelingWeight = 0.4

    init(at now: Date, calendar: Calendar = .current) {
        valence = Self.restValence
        arousal = Self.restArousal(at: now, calendar: calendar)
        updated = now
    }

    /// Resting arousal: 0.25 from 23:00 to 7:00, otherwise 0.45.
    static func restArousal(at date: Date, calendar: Calendar) -> Double {
        let hour = calendar.component(.hour, from: date)
        return hour >= 23 || hour < 7 ? 0.25 : 0.45
    }

    /// The mood at `now`: both values returned toward rest by the time passed; old causes and feelings dropped.
    func at(_ now: Date, calendar: Calendar = .current) -> Affect {
        var a = self
        let k = pow(0.5, max(0, now.timeIntervalSince(updated)) / Self.halfLife)
        let rest = Self.restArousal(at: now, calendar: calendar)
        a.valence = Self.restValence + (valence - Self.restValence) * k
        a.arousal = rest + (arousal - rest) * k
        a.updated = max(updated, now)
        a.causes = causes.filter { now.timeIntervalSince($0.date) < Self.causeHours * 3600 }
        if let felt, now.timeIntervalSince(felt) >= Self.feelingMinutes * 60 { a.feeling = nil; a.felt = nil }
        return a
    }

    /// An event moves the mood by `dv` and `da` (clamped), for `cause`.
    mutating func nudge(dv: Double, da: Double, because cause: String, at now: Date, calendar: Calendar = .current) {
        self = at(now, calendar: calendar)
        valence = min(1, max(-1, valence + dv))
        arousal = min(1, max(0, arousal + da))
        note(cause, at: now)
    }

    /// A feeling the model named pulls the mood part of the way toward its place, and names it for a while.
    mutating func feel(_ report: FeelingReport, at now: Date, calendar: Calendar = .current) {
        self = at(now, calendar: calendar)
        let t = report.feeling.target
        valence += (t.valence - valence) * Self.feelingWeight
        arousal += (t.arousal - arousal) * Self.feelingWeight
        feeling = report.feeling
        felt = now
        let because = report.because.trimmingCharacters(in: .whitespacesAndNewlines)
        note(because.isEmpty ? report.feeling.word : "\(report.feeling.word)：\(because)", at: now)
    }

    /// A cause, newest first; the same cause again only moves to the front.
    private mutating func note(_ text: String, at now: Date) {
        causes.removeAll { $0.text == text }
        causes.insert(Cause(date: now, text: text), at: 0)
        causes = Array(causes.prefix(Self.maxCauses))
    }

    /// How far the mood is from rest at its time, 0…~1.
    func distance(calendar: Calendar = .current) -> Double {
        max(abs(valence - Self.restValence), abs(arousal - Self.restArousal(at: updated, calendar: calendar)))
    }

    /// The mood in a few words: the feeling the model named lately, otherwise the region of the circumplex; "有点"
    /// when close to rest, "很" when far from it.
    func word(calendar: Calendar = .current) -> String {
        let d = distance(calendar: calendar)
        let base: String
        if let feeling { base = feeling.word }
        else if valence >= 0.45 { base = arousal >= 0.65 ? "兴奋" : arousal >= 0.3 ? "开心" : "惬意" }
        else if valence <= -0.25 { base = arousal >= 0.6 ? "烦躁" : arousal >= 0.3 ? "失落" : "低落" }
        else if arousal >= 0.7 { base = "警觉" }
        else if arousal <= 0.2 { base = "困倦" }
        else { return "平静" }
        if base == "平静" { return base }
        return d < 0.25 ? "有点" + base : d >= 0.55 ? "很" + base : base
    }

    /// "（愉悦 0.35，活跃 0.62）".
    var figures: String { String(format: "（愉悦 %.2f，活跃 %.2f）", valence, arousal) }

    /// The mood for a prompt: in words, with what moved it lately ("12 分钟前 主人摸了摸你的头").
    func describe(at now: Date, calendar: Calendar = .current) -> String {
        let a = at(now, calendar: calendar)
        var s = a.word(calendar: calendar)
        if !a.causes.isEmpty {
            s += "。近来影响心情的事：" + a.causes.map { c -> String in
                let minutes = max(0, Int(now.timeIntervalSince(c.date) / 60))
                return (minutes < 1 ? "刚才" : minutes < 60 ? "\(minutes) 分钟前" : "\(minutes / 60) 小时前") + " " + c.text
            }.joined(separator: "；")
        }
        return s + "。"
    }

    /// The tone of voice that fits: "happy" when pleased and lively, "soft" when low or drowsy, nil for the usual one.
    var tone: String? {
        if valence >= 0.4 && arousal >= 0.45 { return "happy" }
        if valence <= -0.3 || arousal <= 0.2 { return "soft" }
        return nil
    }

    /// How much more readily a thought is voiced (subtracted from the urge threshold): up to half a point either way,
    /// by how lively the pet is compared with rest.
    func urgeShift(calendar: Calendar = .current) -> Double {
        min(0.5, max(-0.5, arousal - Self.restArousal(at: updated, calendar: calendar)))
    }
}
