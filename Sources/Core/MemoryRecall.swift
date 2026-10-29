import Foundation

/// What a memory holds. Facts last until they are deleted; episodes and insights fade as human memories do
/// (MemoryBank, after the Ebbinghaus forgetting curve) unless they come up again.
enum MemoryKind: String, Codable, CaseIterable {
    /// A lasting fact about the owner: preferences, allergies, important dates, plans.
    case fact
    /// Something that happened or was talked about on a given day ("the owner's group meeting went badly").
    case episode
    /// The pet's impression of the owner, drawn from several episodes ("the owner has been staying up late").
    case insight
    /// Something the owner must not miss at a given time: a reminder they asked for, or an event of their calendar.
    /// Importance 10; `followUp` is when to bring it up, and until then it stays in the pet's background.
    case reminder
}

/// One entry of the memory bank.
struct Memory: Codable, Identifiable, Equatable {
    var id = UUID()
    var text: String
    var created = Date()
    /// "auto" (from a conversation) or "manual" (added in Settings); manual entries never fade.
    var source = "auto"
    var kind = MemoryKind.fact
    /// 1–10: how much it matters to the owner, as judged by the model (manual entries: 8).
    var importance = 6
    /// When the memory last came up (recalled in a conversation, or followed up); nil: not since it was made.
    var recalled: Date?
    /// How often it came up; every recall makes it last longer.
    var recalls = 0
    /// Episodes: when the pet means to ask how it went, and what about. Cleared once asked or given up.
    var followUp: Date?
    var followUpNote: String?
    /// Times the pet let a due follow-up pass (bad timing); after three it gives up.
    var followUpTries = 0
    /// Episodes: the emotional tone for the owner, −1…1; a strong one makes the memory last longer.
    var emotion: Double?

    init(text: String, kind: MemoryKind = .fact, importance: Int = 6, source: String = "auto", created: Date = Date()) {
        self.text = text
        self.kind = kind
        self.importance = importance
        self.source = source
        self.created = created
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, created, source, kind, importance, recalled, recalls, followUp, followUpNote, followUpTries, emotion
    }

    /// Memories written by earlier versions have only id, text, created and source.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try c.decode(String.self, forKey: .text)
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "auto"
        kind = try c.decodeIfPresent(MemoryKind.self, forKey: .kind) ?? .fact
        importance = try c.decodeIfPresent(Int.self, forKey: .importance) ?? (source == "manual" ? 8 : 6)
        recalled = try c.decodeIfPresent(Date.self, forKey: .recalled)
        recalls = try c.decodeIfPresent(Int.self, forKey: .recalls) ?? 0
        followUp = try c.decodeIfPresent(Date.self, forKey: .followUp)
        followUpNote = try c.decodeIfPresent(String.self, forKey: .followUpNote)
        followUpTries = try c.decodeIfPresent(Int.self, forKey: .followUpTries) ?? 0
        emotion = try c.decodeIfPresent(Double.self, forKey: .emotion)
    }

    /// Days for the retention to fall to 1/e: proportional to the importance, multiplied by every recall, and up to
    /// half as long again for a strongly emotional episode (emotional events are remembered better).
    /// An episode of importance 5 that never comes up again: 10 days, faded after about 25.
    var strengthDays: Double {
        let base: Double
        switch kind {
        case .fact: base = 30
        case .episode: base = 2
        case .insight: base = 4
        // Kept until given (a pending follow-up never fades); once given (importance 4), gone within about a week.
        case .reminder: base = 0.25
        }
        return base * Double(max(1, min(10, importance))) * Double(1 + recalls) * (1 + 0.5 * min(1, abs(emotion ?? 0)))
    }

    /// Retention after the forgetting curve, 0…1: exp(−t / S), t the days since the memory was made or last came up.
    func retention(at now: Date) -> Double {
        let days = max(0, now.timeIntervalSince(recalled ?? created)) / 86400
        return exp(-days / strengthDays)
    }

    /// Faded beyond recall: an automatic episode or insight whose retention fell below `MemoryRecall.fadeThreshold`,
    /// with no follow-up pending.
    func faded(at now: Date) -> Bool {
        kind != .fact && source != "manual" && followUp == nil && retention(at: now) < MemoryRecall.fadeThreshold
    }

    /// Always in the pet's background (Letta's core memory): manual entries and facts of importance 8 or more.
    var pinned: Bool { source == "manual" || (kind == .fact && importance >= 8) || (kind == .reminder && followUp != nil) }

    /// The memory came up: it lasts longer from now on. A long conversation about one thing counts once
    /// (at most one recall in six hours).
    mutating func recall(at now: Date) {
        if let last = recalled, now.timeIntervalSince(last) < 6 * 3600 { return }
        recalled = now
        recalls += 1
    }
}

/// Choosing the memories that matter now (Generative Agents: recency, importance and relevance, each scaled to 0…1),
/// and writing them into a prompt.
enum MemoryRecall {
    /// Retention below which an automatic episode or insight is forgotten.
    static let fadeThreshold = 0.08
    /// Weight of relevance against recency (retention) and importance, which weigh 1 each.
    static let relevanceWeight = 1.5
    /// Relevance (0…1) at which a memory counts as having come up in the conversation.
    static let recallRelevance = 0.6

    struct Scored: Equatable {
        var memory: Memory
        /// 0…1, against the query.
        var relevance: Double
        var score: Double
    }

    /// Terms for matching without word segmentation: characters and character bigrams of Chinese (and other
    /// non-Latin) runs, and lower-cased words of Latin letters and digits.
    static func terms(_ text: String) -> [String: Double] {
        var weights: [String: Double] = [:]
        var word = ""
        var run: [Character] = []
        func flushWord() {
            if word.count >= 2 { weights[word, default: 0] += 1 }
            word = ""
        }
        func flushRun() {
            for c in run { weights[String(c), default: 0] += 0.5 }
            if run.count > 1 { for i in 0..<(run.count - 1) { weights[String(run[i...i + 1]), default: 0] += 1 } }
            run = []
        }
        for ch in text.lowercased() {
            if ch.isASCII, ch.isLetter || ch.isNumber { flushRun(); word.append(ch) }
            else if ch.isLetter || ch.isNumber { flushWord(); run.append(ch) }
            else { flushWord(); flushRun() }
        }
        flushWord()
        flushRun()
        return weights
    }

    /// Cosine similarity of each text to the query over term weights × BM25 inverse document frequency (across
    /// `texts`), so that words every memory shares ("主人") count for little.
    static func lexicalScores(query: String, texts: [String]) -> [Double] {
        let docs = texts.map(terms)
        let q = terms(query)
        guard !q.isEmpty, !docs.isEmpty else { return texts.map { _ in 0 } }
        var df: [String: Double] = [:]
        for d in docs { for t in d.keys { df[t, default: 0] += 1 } }
        let n = Double(docs.count)
        func idf(_ t: String) -> Double { let f = df[t] ?? 0; return log((n - f + 0.5) / (f + 0.5) + 1) }
        // Terms no memory contains cannot match; leaving them out keeps a long query from diluting every score.
        let qv = Dictionary(uniqueKeysWithValues: q.filter { df[$0.key] != nil }.map { ($0.key, $0.value * idf($0.key)) })
        let qNorm = sqrt(qv.values.reduce(0) { $0 + $1 * $1 })
        return docs.map { d in
            var dot = 0.0, norm = 0.0
            for (t, w) in d {
                let v = w * idf(t)
                norm += v * v
                if let x = qv[t] { dot += x * v }
            }
            return norm > 0 && qNorm > 0 ? dot / (sqrt(norm) * qNorm) : 0
        }
    }

    /// Scales scores to 0…1 by the largest one, but never by less than `floor`: a weak best match stays weak.
    static func scaled(_ values: [Double], floor: Double) -> [Double] {
        let top = max(values.max() ?? 0, floor)
        return values.map { max(0, $0) / top }
    }

    /// Memories by score (best first): retention + importance / 10 + relevanceWeight × relevance. Relevance is the term
    /// match against `query`, averaged with the semantic similarity (1 − cosine distance of sentence embeddings, one
    /// per memory) when given; without a query only recency and importance count.
    static func rank(_ memories: [Memory], query: String?, now: Date, semantic: [Double]? = nil) -> [Scored] {
        var relevance = memories.map { _ in 0.0 }
        if let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !memories.isEmpty {
            relevance = scaled(lexicalScores(query: query, texts: memories.map(\.text)), floor: 0.3)
            if let semantic, semantic.count == memories.count, let lo = semantic.min(), let hi = semantic.max() {
                // Sentence embeddings place unrelated sentences at a similarity of about 0.55–0.7: only the spread counts.
                let spread = semantic.map { ($0 - lo) / max(hi - lo, 0.1) }
                relevance = zip(relevance, spread).map { 0.5 * $0 + 0.5 * $1 }
            }
        }
        return memories.indices.map { i in
            let m = memories[i]
            let score = m.retention(at: now) + Double(max(1, min(10, m.importance))) / 10 + relevanceWeight * relevance[i]
            return Scored(memory: m, relevance: relevance[i], score: score)
        }
        .sorted { $0.score != $1.score ? $0.score > $1.score : $0.memory.created > $1.memory.created }
    }

    /// The best memories that fit into `budget` characters of prompt lines, in score order.
    static func select(_ ranked: [Scored], budget: Int, now: Date, calendar: Calendar) -> [Scored] {
        var used = 0
        var chosen: [Scored] = []
        for s in ranked {
            let cost = line(s.memory, now: now, calendar: calendar).count + 1
            if used + cost > budget { continue }
            used += cost
            chosen.append(s)
        }
        return chosen
    }

    /// "2026-10-27，昨天" (today, yesterday, the day before, otherwise "N 天前").
    static func dayLabel(_ date: Date, now: Date, calendar: Calendar) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        let relative: String
        switch days {
        case ..<1: relative = "今天"
        case 1: relative = "昨天"
        case 2: relative = "前天"
        default: relative = "\(days) 天前"
        }
        return ReminderRules.dayStamp(date, calendar) + "，" + relative
    }

    /// "yyyy-MM-dd HH:mm" in the calendar's time zone.
    static func minuteStamp(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(format: "%04d-%02d-%02d %02d:%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
    }

    /// One prompt line: the day for facts and episodes, and a pending follow-up.
    static func line(_ m: Memory, now: Date, calendar: Calendar, label: String? = nil) -> String {
        var s = "- " + (label.map { "\($0) " } ?? "")
        switch m.kind {
        case .fact: s += "[\(ReminderRules.dayStamp(m.created, calendar))] \(m.text)"
        case .episode: s += "[\(dayLabel(m.created, now: now, calendar: calendar))] \(m.text)"
        case .insight: s += m.text
        case .reminder:
            s += "【提醒】" + (m.followUp.map { "[\(minuteStamp($0, calendar: calendar)) 提醒] " } ?? "[已提醒] ") + m.text
            return s
        }
        if let at = m.followUp {
            s += "（打算 \(minuteStamp(at, calendar: calendar)) 问问" + (m.followUpNote.map { "：\($0)" } ?? "") + "）"
        }
        return s
    }

    /// Memories grouped under headings: facts, then episodes (oldest first, as they happened), then impressions.
    static func render(_ memories: [Memory], now: Date, calendar: Calendar) -> String {
        let groups: [(MemoryKind, String)] = [(.reminder, "主人交代的提醒与日程（重要，到点务必提醒）"), (.fact, "关于主人的长期事实"),
                                              (.episode, "经历（情景记忆，越久越模糊）"), (.insight, "你对主人的印象")]
        var parts: [String] = []
        for (kind, title) in groups {
            let items = memories.filter { $0.kind == kind }.sorted { $0.created < $1.created }
            guard !items.isEmpty else { continue }
            parts.append("### \(title)\n" + items.map { line($0, now: now, calendar: calendar) }.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n")
    }
}
