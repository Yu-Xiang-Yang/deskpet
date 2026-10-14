import Foundation
import Combine

/// One remembered fact about the owner.
struct Memory: Codable, Identifiable, Equatable {
    var id = UUID()
    var text: String
    var created = Date()
    /// "auto" (from a conversation) or "manual" (added in Settings).
    var source = "auto"
}

/// The memory bank: ~/Library/Application Support/DeskPet/memories.json.
/// Every model call receives the memories as background (newest first, within a size budget).
final class MemoryStore: ObservableObject {
    static let shared = MemoryStore()

    @Published private(set) var items: [Memory] = []
    private let file: URL

    /// Characters of memory text given to the model; older memories beyond it are left out.
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

    /// Adds a memory unless it repeats one already kept; a near-duplicate replaces the older wording.
    /// Returns false when nothing new was stored.
    @discardableResult
    func add(_ text: String, source: String = "auto") -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return false }
        if let i = items.firstIndex(where: { MemoryText.isDuplicate($0.text, trimmed) }) {
            if MemoryText.normalized(items[i].text) == MemoryText.normalized(trimmed) { return false }
            items[i].text = trimmed
            items[i].created = Date()
        } else {
            items.insert(Memory(text: trimmed, source: source), at: 0)
        }
        save()
        return true
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

    /// The prompt section listing the memories, newest first, within `promptBudget` characters.
    var promptSection: String {
        guard !items.isEmpty else { return "" }
        var lines: [String] = []
        var used = 0
        for m in items.sorted(by: { $0.created > $1.created }) {
            let line = "- [\(ReminderRules.dayStamp(m.created, .current))] \(m.text)"
            used += line.count
            if used > Self.promptBudget { break }
            lines.append(line)
        }
        return "\n\n## 记忆库（关于主人的长期记忆，按时间由新到旧）\n" + lines.joined(separator: "\n")
    }
}
