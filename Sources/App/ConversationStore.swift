import Foundation

/// One stored message. Assistant messages keep the provider wire messages of their turn
/// (assistant responses and tool results, in order) so that a research conversation is replayed
/// append-only, exactly as it was sent, as long as the provider does not change.
struct StoredMessage: Codable, Identifiable, Equatable {
    enum Role: String, Codable { case user, assistant, error }

    var id = UUID()
    var role: Role
    /// Text shown in the conversation view.
    var text: String
    var date = Date()
    /// User: the text actually sent (may carry context such as the time). Assistant (pet): the raw model output.
    var raw: String?
    var citations: [Citation]?
    var wireProvider: String?
    var wire: [JSON]?
    var model: String?
    /// A user message whose request failed; it is left out of later requests.
    var failed: Bool?
}

struct Conversation: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case daily, research }

    var id: String
    var title: String
    var kind: Kind
    var created = Date()
    var updated = Date()
    var messages: [StoredMessage] = []

    struct Summary: Codable, Identifiable, Equatable {
        var id: String
        var title: String
        var kind: Kind
        var updated: Date
        var count: Int
    }

    var summary: Summary { Summary(id: id, title: title, kind: kind, updated: updated, count: messages.count) }
}

/// JSON files under ~/Library/Application Support/DeskPet/conversations.
final class ConversationStore {
    static let shared = ConversationStore()
    static let dailyID = "daily"

    private let dir: URL
    private var cache: [String: Conversation] = [:]
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Posted with the conversation id as object whenever a conversation changes.
    static let didChange = Notification.Name("ConversationStoreDidChange")

    init(directory: URL = AppPaths.conversationsDir) {
        dir = AppPaths.ensure(directory)
    }

    private func url(_ id: String) -> URL { dir.appendingPathComponent("\(id).json") }

    func list() -> [Conversation.Summary] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var result = files.filter { $0.pathExtension == "json" }.compactMap { file -> Conversation.Summary? in
            load(file.deletingPathExtension().lastPathComponent)?.summary
        }
        if !result.contains(where: { $0.id == Self.dailyID }) { result.append(daily().summary) }
        // The daily conversation stays on top; research conversations follow, newest first.
        return result.sorted {
            if ($0.kind == .daily) != ($1.kind == .daily) { return $0.kind == .daily }
            return $0.updated > $1.updated
        }
    }

    func load(_ id: String) -> Conversation? {
        if let cached = cache[id] { return cached }
        guard let data = try? Data(contentsOf: url(id)), let conversation = try? decoder.decode(Conversation.self, from: data) else {
            return nil
        }
        cache[id] = conversation
        return conversation
    }

    func daily() -> Conversation {
        load(Self.dailyID) ?? Conversation(id: Self.dailyID, title: tr("日常对话", "Daily chat"), kind: .daily)
    }

    func newResearch() -> Conversation {
        Conversation(id: UUID().uuidString.lowercased(), title: tr("新的科研对话", "New research chat"), kind: .research)
    }

    func save(_ conversation: Conversation) {
        var c = conversation
        c.updated = Date()
        cache[c.id] = c
        if let data = try? encoder.encode(c) {
            try? data.write(to: url(c.id), options: .atomic)
        }
        NotificationCenter.default.post(name: Self.didChange, object: c.id)
    }

    func delete(_ id: String) {
        cache[id] = nil
        try? FileManager.default.removeItem(at: url(id))
        NotificationCenter.default.post(name: Self.didChange, object: id)
    }

    func rename(_ id: String, to title: String) {
        guard var c = load(id) else { return }
        c.title = title
        save(c)
    }
}
