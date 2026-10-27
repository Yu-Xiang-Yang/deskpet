import Foundation

/// What the pet saw on the owner's screen: the app in front and the model's one-sentence account of what the owner is
/// doing. The screenshot itself is never kept.
struct ScreenGlance: Equatable, Identifiable {
    var id = UUID()
    /// When the scene was last confirmed (a new screenshot, or the same app and window as before).
    var date: Date
    /// When the screenshot behind `activity` was taken.
    var looked: Date
    var app: String
    /// Title of the front window, to tell whether the scene changed.
    var title: String?
    var activity: String
    /// "work", "study", "leisure", "communication" or "other".
    var kind: String
    /// Seen without a screenshot (an app the owner left out of capture).
    var unseen = false
}

enum ScreenGlances {
    static let kinds = ["work", "study", "leisure", "communication", "other"]
    /// Longest side of the screenshot sent to the model, in pixels.
    static let maxSide = 1280

    /// App names in the owner's list, separated by commas, "、" or new lines.
    static func names(_ list: String) -> [String] {
        list.components(separatedBy: CharacterSet(charactersIn: ",，、;；\n"))
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
    }

    /// Whether the app is left out of capture: its name contains a name of the owner's list (case-insensitive).
    static func excluded(name: String, list: String) -> Bool {
        let app = name.lowercased()
        return names(list).contains { app.contains($0) }
    }

    /// The same scene as the last glance: same app and window title, with a screenshot under `window` seconds old.
    static func sameScene(_ last: ScreenGlance?, app: String, title: String?, now: Date, window: TimeInterval = 1800) -> Bool {
        guard let last, !last.unseen, last.app == app, last.title == title, title?.isEmpty == false else { return false }
        return now.timeIntervalSince(last.looked) < window
    }

    /// Screenshot size within `maxSide`, keeping the aspect ratio.
    static func size(width: Int, height: Int, maxSide: Int = maxSide) -> (width: Int, height: Int) {
        let longest = max(width, height)
        guard longest > maxSide, longest > 0 else { return (max(1, width), max(1, height)) }
        let scale = Double(maxSide) / Double(longest)
        return (max(1, Int((Double(width) * scale).rounded())), max(1, Int((Double(height) * scale).rounded())))
    }

    static var schema: JSON {
        [
            "type": "object",
            "additionalProperties": false,
            "required": ["activity", "kind"],
            "properties": [
                "activity": ["type": "string", "description": "One sentence: what the owner is doing now."],
                "kind": ["type": "string", "enum": .array(kinds.map { .string($0) })],
            ],
        ]
    }

    /// Reads the model's account tolerantly; an unknown kind becomes "other".
    static func parse(_ raw: String) -> (activity: String, kind: String)? {
        for candidate in PetReply.jsonCandidates(in: raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
            guard let json = try? JSON.parse(candidate),
                  let activity = json["activity"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !activity.isEmpty else { continue }
            let kind = json["kind"]?.string.flatMap { kinds.contains($0) ? $0 : nil } ?? "other"
            return (activity.count > 120 ? String(activity.prefix(120)) + "…" : activity, kind)
        }
        return nil
    }

    static func kindTitle(_ kind: String) -> String {
        switch kind {
        case "work": return "工作"
        case "study": return "学习"
        case "leisure": return "休闲"
        case "communication": return "沟通"
        default: return "其它"
        }
    }

    /// "主人屏幕上（3 分钟前，工作）：在 Xcode 里调试代码" for prompts; nil when the glance is older than `maxAge`.
    static func contextLine(_ glance: ScreenGlance?, now: Date, maxAge: TimeInterval = 1200) -> String? {
        guard let g = glance, now.timeIntervalSince(g.date) < maxAge else { return nil }
        let minutes = Int(now.timeIntervalSince(g.date) / 60)
        return "主人屏幕上（\(minutes < 1 ? "刚刚" : "\(minutes) 分钟前")，\(kindTitle(g.kind))）：\(g.activity)"
    }
}
