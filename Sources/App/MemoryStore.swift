import Foundation
import Combine

/// The memory bank: ~/Library/Application Support/DeskPet/memories.json. It keeps facts about the owner, episodes
/// (what happened, day by day) and impressions; episodes and impressions fade unless they come up again.
/// Pinned memories are always in the pet's background; the others are recalled when they matter (MemoryRecall).
final class MemoryStore: ObservableObject {
    static let shared = MemoryStore()

    @Published private(set) var items: [Memory] = []
    private let file: URL
    var calendar = Calendar.current
    /// Semantic similarity of the query to each text (sentence embeddings), or nil when unavailable.
    var semantic: ((String, [String]) -> [Double]?)?

    /// Characters of the memories always in the background: pinned facts and the strongest impressions.
    static let coreBudget = 1200
    /// Characters of the memories recalled for the current message.
    static let recallBudget = 1800
    /// Characters of memories given without a query (research mode), best by recency and importance.
    static let promptBudget = 2400

    init(file: URL = AppPaths.ensure(AppPaths.dataDir).appendingPathComponent("memories.json")) {
        self.file = file
        if let data = try? Data(contentsOf: file) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            items = (try? decoder.decode([Memory].self, from: data)) ?? []
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        if let data = try? encoder.encode(items) { try? data.write(to: file, options: .atomic) }
    }

    /// Adds a memory unless it repeats one of the same kind already kept; a near-duplicate replaces the older
    /// wording. Returns false when nothing new was stored.
    @discardableResult
    func add(_ text: String, source: String = "auto", kind: MemoryKind = .fact, importance: Int? = nil) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return false }
        if let i = items.firstIndex(where: { $0.kind == kind && MemoryText.isDuplicate($0.text, trimmed) }) {
            if MemoryText.normalized(items[i].text) == MemoryText.normalized(trimmed) { return false }
            items[i].text = trimmed
            items[i].created = Date()
            if let importance { items[i].importance = max(items[i].importance, importance) }
        } else {
            items.insert(Memory(text: trimmed, kind: kind, importance: importance ?? (source == "manual" ? 8 : 6), source: source), at: 0)
        }
        save()
        return true
    }

    /// Adds an episode unless one like it is kept already; a repeated one only gains a missing follow-up.
    @discardableResult
    func addEpisode(_ episode: MemoryDigest.Episode, at now: Date) -> Bool {
        if let i = items.firstIndex(where: { $0.kind == .episode && MemoryText.isDuplicate($0.text, episode.text) }) {
            guard items[i].followUp == nil, let at = episode.followUp else { return false }
            items[i].followUp = at
            items[i].followUpNote = episode.followUpNote
        } else {
            var m = Memory(text: episode.text, kind: .episode, importance: episode.importance, created: now)
            m.followUp = episode.followUp
            m.followUpNote = episode.followUpNote
            items.insert(m, at: 0)
        }
        save()
        return true
    }

    /// Applies a consolidation of the conversation; `labels` map the labels shown to the model to memories.
    /// Returns how many memories were added, changed and removed.
    @discardableResult
    func apply(_ digest: MemoryDigest, labels: [String: UUID], at now: Date) -> (added: Int, changed: Int, removed: Int) {
        var added = 0, changed = 0, removed = 0
        for u in digest.updates {
            guard let id = labels[u.label], let i = items.firstIndex(where: { $0.id == id }), items[i].source != "manual" else { continue }
            if let text = u.text {
                guard MemoryText.normalized(text) != MemoryText.normalized(items[i].text) else { continue }
                items[i].text = text
                changed += 1
            } else {
                items.remove(at: i)
                removed += 1
            }
        }
        if changed + removed > 0 { save() }
        for f in digest.facts where add(f.text, kind: .fact, importance: f.importance) { added += 1 }
        for e in digest.episodes where addEpisode(e, at: now) { added += 1 }
        if let insight = digest.insight, add(insight.text, kind: .insight, importance: insight.importance) { added += 1 }
        return (added, changed, removed)
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        save()
    }

    /// Removes the memories that mention `keyword`; returns how many were removed.
    @discardableResult
    func forget(_ keyword: String) -> Int {
        let key = MemoryText.normalized(keyword)
        guard !key.isEmpty else { return 0 }
        let before = items.count
        items.removeAll { MemoryText.normalized($0.text).contains(key) }
        save()
        return before - items.count
    }

    func removeAll() {
        items = []
        save()
    }

    // MARK: Recall and forgetting

    /// The memories came up in a conversation: they last longer from now on.
    func recall(_ ids: [UUID], at now: Date) {
        guard !ids.isEmpty else { return }
        for i in items.indices where ids.contains(items[i].id) { items[i].recall(at: now) }
        save()
    }

    /// Gives up follow-ups overdue by more than two days, then removes the episodes and impressions that faded away;
    /// returns those.
    @discardableResult
    func forgetFaded(at now: Date) -> [Memory] {
        var changed = false
        for i in items.indices where items[i].followUp.map({ now.timeIntervalSince($0) > 2 * 86400 }) == true {
            items[i].followUp = nil
            changed = true
        }
        let gone = items.filter { $0.faded(at: now) }
        items.removeAll { $0.faded(at: now) }
        if changed || !gone.isEmpty { save() }
        return gone
    }

    // MARK: Follow-ups

    /// Episodes whose follow-up time has come, earliest first.
    func dueFollowUps(at now: Date) -> [Memory] {
        items.filter { $0.followUp.map { $0 <= now } == true }.sorted { $0.followUp! < $1.followUp! }
    }

    /// The pet asked about the episode (or gave the reminder): no further follow-up, and the memory came up. A given
    /// reminder is no longer important and fades within days.
    func followedUp(_ id: UUID, at now: Date) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].followUp = nil
        items[i].recall(at: now)
        if items[i].kind == .reminder { items[i].importance = min(items[i].importance, 4) }
        save()
    }

    // MARK: Reminders

    /// A reminder the owner asked for: importance 10, brought up at `at`.
    @discardableResult
    func addReminder(_ text: String, at: Date, source: String = "remind") -> UUID {
        var m = Memory(text: text.trimmingCharacters(in: .whitespacesAndNewlines), kind: .reminder, importance: 10, source: source)
        m.followUp = at
        items.insert(m, at: 0)
        save()
        return m.id
    }

    /// The calendar's events as reminders (CalendarAlerts.reminder): new ones are added (to be given at once when their
    /// time has passed), changed ones updated, and those of events that are gone (deleted or moved) are removed while
    /// still to come. Given reminders stay as they are.
    func syncCalendar(_ entries: [(source: String, text: String, at: Date)], now: Date) {
        let keep = Set(entries.map(\.source))
        let before = items.count
        items.removeAll { $0.kind == .reminder && $0.source.hasPrefix("calendar:") && $0.followUp != nil && !keep.contains($0.source) }
        var changed = items.count != before
        for e in entries {
            if let i = items.firstIndex(where: { $0.source == e.source }) {
                guard items[i].followUp != nil else { continue }
                if items[i].text != e.text || items[i].followUp != max(e.at, now) && e.at > now {
                    items[i].text = e.text
                    if e.at > now { items[i].followUp = e.at }
                    changed = true
                }
            } else {
                var m = Memory(text: e.text, kind: .reminder, importance: 10, source: e.source)
                m.followUp = max(e.at, now)
                items.insert(m, at: 0)
                changed = true
            }
        }
        if changed { save() }
    }

    /// The pet let a due follow-up pass: it tries again at `retry`, and gives up after the third time.
    func postponeFollowUp(_ id: UUID, retry: Date) {
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].followUp != nil else { return }
        items[i].followUpTries += 1
        items[i].followUp = items[i].followUpTries >= 3 ? nil : retry
        save()
    }

    // MARK: Prompt sections

    /// Always in the background: pinned memories, then the three most important impressions, within `coreBudget`.
    /// The order does not depend on the time, so that the system prompt stays the same between messages.
    func coreMemories() -> [Memory] {
        let pinned = items.filter(\.pinned).sorted { ($0.importance, $0.created) > ($1.importance, $1.created) }
        let insights = items.filter { $0.kind == .insight && !$0.pinned }
            .sorted { ($0.importance, $0.created) > ($1.importance, $1.created) }.prefix(3)
        var used = 0
        var result: [Memory] = []
        for m in pinned + insights {
            let cost = m.text.count + 16
            if used + cost > Self.coreBudget { continue }
            used += cost
            result.append(m)
        }
        return result
    }

    /// The system-prompt section of the core memories, or an empty string.
    func coreSection(at now: Date) -> String {
        let core = coreMemories()
        guard !core.isEmpty else { return "" }
        return "\n\n## 记忆库（常驻部分；与话题相关的其它记忆会附在主人的消息前）\n" + MemoryRecall.render(core, now: now, calendar: calendar)
    }

    /// The memories that matter for `query`, beyond the core ones (Generative Agents retrieval: recency, importance,
    /// relevance), within `recallBudget`: the prompt text, and the memories relevant enough to count as having come up.
    func recallBlock(for query: String, at now: Date) -> (text: String, relevant: [UUID]) {
        let core = Set(coreMemories().map(\.id))
        let pool = items.filter { !core.contains($0.id) }
        guard !pool.isEmpty else { return ("", []) }
        let ranked = MemoryRecall.rank(pool, query: query, now: now, semantic: semantic?(query, pool.map(\.text)))
        let chosen = MemoryRecall.select(ranked, budget: Self.recallBudget, now: now, calendar: calendar)
        guard !chosen.isEmpty else { return ("", []) }
        let relevant = chosen.filter { $0.relevance >= MemoryRecall.recallRelevance }.map(\.memory.id)
        return (MemoryRecall.render(chosen.map(\.memory), now: now, calendar: calendar), relevant)
    }

    /// The memories without a query (research mode): pinned ones first, then by recency and importance, within
    /// `promptBudget` characters.
    var promptSection: String {
        let now = Date()
        let ranked = MemoryRecall.rank(items, query: nil, now: now)
        let ordered = ranked.filter(\.memory.pinned) + ranked.filter { !$0.memory.pinned }
        let chosen = MemoryRecall.select(ordered, budget: Self.promptBudget, now: now, calendar: calendar)
        guard !chosen.isEmpty else { return "" }
        return "\n\n## 记忆库（关于主人的记忆）\n" + MemoryRecall.render(chosen.map(\.memory), now: now, calendar: calendar)
    }

    /// The memories for consolidating `transcript`: facts and impressions most relevant to it (F1…, at most 30) and the
    /// episodes of the last three days (E1…), with the labels for `apply`. Manual entries are listed without labels:
    /// only the owner changes them.
    func digestContext(for transcript: String, at now: Date) -> (text: String, labels: [String: UUID]) {
        var labels: [String: UUID] = [:]
        var lines: [String] = []
        let manual = items.filter { $0.source == "manual" }
        if !manual.isEmpty {
            lines.append("### 主人手动记下的（只读）")
            lines += manual.map { MemoryRecall.line($0, now: now, calendar: calendar) }
        }
        let lasting = items.filter { $0.source != "manual" && $0.kind != .episode }
        let facts = MemoryRecall.rank(lasting, query: transcript, now: now).prefix(30).map(\.memory)
        if !facts.isEmpty {
            lines.append("### 长期事实与印象")
            for (i, m) in facts.enumerated() {
                labels["F\(i + 1)"] = m.id
                lines.append(MemoryRecall.line(m, now: now, calendar: calendar, label: "F\(i + 1)"))
            }
        }
        let recent = items.filter { $0.source != "manual" && $0.kind == .episode && now.timeIntervalSince($0.created) < 3 * 86400 }
            .sorted { $0.created < $1.created }
        if !recent.isEmpty {
            lines.append("### 记忆中已有的近三天经历")
            for (i, m) in recent.enumerated() {
                labels["E\(i + 1)"] = m.id
                lines.append(MemoryRecall.line(m, now: now, calendar: calendar, label: "E\(i + 1)"))
            }
        }
        return (lines.isEmpty ? "（记忆库为空）" : lines.joined(separator: "\n"), labels)
    }
}
