import Foundation

/// The pet's identity at the head of every prompt of its own: the owner's persona text first, then the name, the
/// character's appearance and, with the default persona only, the character's speech habit ("habit" in pet-map.json),
/// since a persona the owner wrote decides how the pet speaks.
///
/// The prompts are written with "主人" for the user. When the owner gave a name to be called by, every text the model
/// reads or the pet says goes through `addressed`, which puts that name in its place: prompts, context, memories and
/// spoken lines then all call the owner the same.
enum Persona {
    /// The word for the user in the prompts as written.
    static let ownerRole = "主人"
    /// The settings tab of that name, kept as it is.
    private static let settingsTab = "主人信息"

    static func section(persona: String, isDefault: Bool, name: String, look: String?, habit: String?, ownerName: String) -> String {
        var s = persona.trimmingCharacters(in: .whitespacesAndNewlines)
        s += "\n\n你的名字是「\(name)」。"
        if let look = sentence(look) { s += "你的外形是" + look }
        if isDefault, let habit = sentence(habit) { s += habit }
        let owner = ownerName.trimmingCharacters(in: .whitespaces)
        if !owner.isEmpty { s += "称呼对方时一律用「\(owner)」。" }
        return s
    }

    /// The text with the owner's name in place of the role word, when they gave one ("设置 → 主人信息" stays).
    static func addressed(_ text: String, ownerName: String) -> String {
        let owner = ownerName.trimmingCharacters(in: .whitespaces)
        guard !owner.isEmpty, owner != ownerRole else { return text }
        let tab = "\u{0}tab\u{0}"
        return text.replacingOccurrences(of: settingsTab, with: tab)
            .replacingOccurrences(of: ownerRole, with: owner)
            .replacingOccurrences(of: tab, with: settingsTab)
    }

    /// The text with a full stop at its end, or nil when empty.
    private static func sentence(_ text: String?) -> String? {
        guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return "。！？.!?".contains(t.last!) ? t : t + "。"
    }
}
