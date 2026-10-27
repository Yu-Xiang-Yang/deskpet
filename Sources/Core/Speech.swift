import Foundation

/// The words of a bubble as they are spoken (Settings → General → Voice): Markdown markup, code, formulas, tables,
/// links, emoji and kaomoji are left out, ranges and arrows are put into words, and line breaks become pauses.
enum SpeechText {
    static func clean(_ text: String) -> String {
        var s = text
        // Parts that cannot be read aloud: code blocks (an unclosed fence runs to the end), formulas, pictures, addresses.
        s = replace(s, #"```[\s\S]*?(```|$)"#, "\n")
        s = replace(s, #"\$\$[\s\S]*?\$\$"#, " ")
        s = replace(s, #"\\\[[\s\S]*?\\\]"#, " ")
        s = replace(s, #"\\\([\s\S]*?\\\)"#, " ")
        // Inline formulas as Pandoc reads them, so that prices ("$1.50 or $2") stay.
        s = replace(s, #"\$(?=\S)[^$\n]*?\S\$(?!\d)"#, " ")
        s = replace(s, #"!\[[^\]]*\]\([^)]*\)"#, " ")
        s = replace(s, #"\[([^\]]+)\]\([^)]*\)"#, "$1")
        s = replace(s, #"https?://[^\s，。）)]+"#, " ")
        s = replace(s, #"`([^`\n]*)`"#, "$1")

        // Line by line: tables and rules go, heading, quote and list markers go, and each line ends with a pause.
        var lines: [String] = []
        for raw in s.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("|") || line.range(of: #"^([-*_=]\s*){3,}$"#, options: .regularExpression) != nil { continue }
            line = replace(line, #"^(#{1,6}\s+|>\s*|[-*+•]\s+|\d{1,3}[.)]\s+|\d{1,3}、)"#, "")
            line = line.trimmingCharacters(in: .whitespaces)
            line = replace(line, #"[：:，,、；;\s]+$"#, "")
            guard !line.isEmpty else { continue }
            if let last = line.last, !"。！？!?.…".contains(last) {
                line += line.contains(where: isCJK) ? "。" : "."
            }
            lines.append(line)
        }
        s = lines.joined(separator: " ")

        // Symbols a voice would read out by name.
        s = s.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "~~", with: "")
        s = replace(s, #"(\d)\s*[~～–—]\s*(\d)"#, hasHan(s) ? "$1到$2" : "$1 to $2")
        s = replace(s, #"\s*(→|->|=>|⇒|⟶)\s*"#, "，")
        s = replace(s, #"\s+·\s+"#, "，")
        // Kaomoji: brackets around nothing but symbols ("(｡･ω･｡)", "(^▽^)"); "（笑）" or "(Nature)" stay.
        s = replace(s, #"[(（][^()（）\p{Han}A-Za-z0-9]{1,12}[)）]"#, " ")
        s = replace(s, #"[~～]+"#, "，")
        s = replace(s, #"[*^_✓✔✗✘★☆♪♫♡♥]"#, " ")
        s = String(String.UnicodeScalarView(s.unicodeScalars.filter { !isEmoji($0) }))

        // Spacing and punctuation that piled up where something was left out.
        s = replace(s, #"[ \t\x{3000}]+"#, " ")
        s = replace(s, #"\s*([，、。！？；：])\s*"#, "$1")
        s = replace(s, #"\s+([,.!?;:])"#, "$1")
        s = replace(s, #"[，,、；;：:]+([。！？!?…])"#, "$1")
        s = replace(s, #"([。！？!?；;])[，,、。；;]+"#, "$1")
        s = replace(s, #"([，,、])[，,、]+"#, "$1")
        s = replace(s, #"\.\s*([，。！？])"#, "$1")
        s = replace(s, #"^[\s，,、。.；;：:！？!?]+"#, "")
        s = replace(s, #"[\s，,、：:；;]+$"#, "")
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.contains(where: { $0.isLetter || $0.isNumber }) ? s : ""
    }

    /// At most about `limit` characters of `text`, cut after the last sentence end within the limit when one lies in
    /// its latter two thirds, otherwise at the limit; `truncated` tells whether anything was left out.
    static func excerpt(_ text: String, limit: Int) -> (text: String, truncated: Bool) {
        let chars = Array(text)
        guard chars.count > limit else { return (text, false) }
        let ends: Set<Character> = ["。", "！", "？", "!", "?", "；", "…"]
        var cut = limit
        for i in stride(from: limit - 1, through: limit / 3, by: -1) {
            if ends.contains(chars[i]) || (chars[i] == "." && i + 1 < chars.count && chars[i + 1] == " ") {
                cut = i + 1
                break
            }
        }
        return (String(chars[..<cut]).trimmingCharacters(in: .whitespaces), true)
    }

    /// The BCP 47 language of the voice for `text`: Japanese with kana, Korean with Hangul, Chinese with Han
    /// characters (a Chinese voice also reads the English words in between), English otherwise.
    static func language(of text: String) -> String {
        var kana = 0, hangul = 0, han = 0
        for u in text.unicodeScalars {
            switch u.value {
            case 0x3041...0x30FA: kana += 1
            case 0xAC00...0xD7AF: hangul += 1
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF: han += 1
            default: break
            }
        }
        if kana >= 2 { return "ja-JP" }
        if hangul > 0 { return "ko-KR" }
        if han > 0 { return "zh-CN" }
        return "en-US"
    }

    private static func replace(_ s: String, _ pattern: String, _ template: String) -> String {
        s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
    }

    private static func isCJK(_ c: Character) -> Bool {
        c.unicodeScalars.contains { (0x3040...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) }
    }

    private static func hasHan(_ s: String) -> Bool { s.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) } }

    /// Emoji and their joiners and modifiers; digits, "#" and "*" (emoji only in keycaps) are kept.
    private static func isEmoji(_ u: Unicode.Scalar) -> Bool {
        if u.value == 0xFE0F || u.value == 0x200D || u.value == 0x20E3 { return true }
        let p = u.properties
        return p.isEmojiPresentation || (p.isEmoji && u.value >= 0x2190)
    }
}

/// An installed system voice, as far as choosing the most natural one is concerned.
struct SpeechVoice: Equatable {
    var identifier: String
    var name: String
    /// BCP 47, e.g. "zh-CN".
    var language: String
    /// 1 standard (compact), 2 enhanced, 3 premium, as in AVSpeechSynthesisVoiceQuality.
    var quality: Int
    var novelty: Bool = false
    var female: Bool? = nil
}

enum SpeechVoices {
    /// Voices that sound synthetic whatever their quality: the Eloquence voices and the old MacinTalk voices.
    static func isSynthetic(_ v: SpeechVoice) -> Bool {
        v.identifier.hasPrefix("com.apple.eloquence.") || v.identifier.hasPrefix("com.apple.speech.synthesis.voice.")
    }

    /// The voices for `language` ("zh-CN"), the most natural first: premium before enhanced before standard, Siri
    /// voices first among equals, then the exact region, then female voices (the pet's persona); novelty voices are
    /// left out and synthetic ones come last. Cantonese (zh-HK) only counts for itself.
    static func ranked(_ voices: [SpeechVoice], for language: String) -> [SpeechVoice] {
        let family = language.split(separator: "-").first.map(String.init)?.lowercased() ?? language.lowercased()
        func matches(_ v: SpeechVoice) -> Bool {
            let lang = v.language.replacingOccurrences(of: "_", with: "-")
            guard lang.lowercased().hasPrefix(family) else { return false }
            return (lang.caseInsensitiveCompare("zh-HK") == .orderedSame) == (language.caseInsensitiveCompare("zh-HK") == .orderedSame)
        }
        func score(_ v: SpeechVoice) -> Int {
            var s = v.quality * 100
            if v.identifier.lowercased().contains("siri") { s += 50 }
            if v.language.replacingOccurrences(of: "_", with: "-").caseInsensitiveCompare(language) == .orderedSame { s += 20 }
            if v.female == true { s += 5 }
            if isSynthetic(v) { s -= 1000 }
            return s
        }
        return voices.filter { !$0.novelty && matches($0) }
            .sorted { score($0) != score($1) ? score($0) > score($1) : $0.name < $1.name }
    }

    /// The voice for text in `language`: the owner's choice when it speaks that language, otherwise the most natural.
    static func pick(_ voices: [SpeechVoice], language: String, preferred: String) -> SpeechVoice? {
        let candidates = ranked(voices, for: language)
        return candidates.first { $0.identifier == preferred } ?? candidates.first
    }

    /// Whether an enhanced or premium voice that does not sound synthetic is installed for `language`.
    static func hasNatural(_ voices: [SpeechVoice], language: String) -> Bool {
        ranked(voices, for: language).contains { $0.quality >= 2 && !isSynthetic($0) }
    }
}

/// Speech synthesis through an OpenAI-compatible endpoint (`POST {base}/audio/speech`), as offered by SiliconFlow
/// (CosyVoice2) and OpenAI among others; the response is the audio itself.
enum CloudSpeech {
    static let siliconFlowURL = "https://api.siliconflow.cn/v1"
    static let siliconFlowModel = "FunAudioLLM/CosyVoice2-0.5B"
    /// "diana", the cheerful female preset voice.
    static let siliconFlowVoice = "FunAudioLLM/CosyVoice2-0.5B:diana"

    /// `{base}/audio/speech` for a base URL such as "https://api.siliconflow.cn/v1" (a full endpoint is kept as is).
    static func endpoint(baseURL: String) -> URL? {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        if !base.hasSuffix("/audio/speech") { base += "/audio/speech" }
        guard let url = URL(string: base), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else { return nil }
        return url
    }

    /// The request body; gpt-4o speech models also get a description of the tone.
    static func body(text: String, model: String, voice: String, speed: Double) -> JSON {
        var body: [String: JSON] = [
            "model": .string(model.trimmingCharacters(in: .whitespaces)),
            "input": .string(text),
            "voice": .string(voice.trimmingCharacters(in: .whitespaces)),
            "response_format": "mp3",
            "speed": .number(min(4, max(0.25, speed))),
        ]
        if model.hasPrefix("gpt-4o") {
            body["instructions"] = "Speak like a lively, warm young friend in a casual conversation: natural pace, relaxed and expressive."
        }
        return .object(body)
    }

    /// The service's explanation of a failed request, or the HTTP status.
    static func errorMessage(_ data: Data, status: Int) -> String {
        if let json = try? JSON.parse(data) {
            let message = json["error"]?["message"]?.string ?? json["error"]?.string ?? json["message"]?.string ?? json["detail"]?.string
            if let message, !message.isEmpty { return "HTTP \(status): \(message)" }
        }
        return "HTTP \(status)"
    }
}

/// Bubbles waiting to be spoken. When more than `capacity` wait, the oldest are dropped, so that the voice never falls
/// far behind the bubbles on screen.
struct SpeechQueue<Item> {
    let capacity: Int
    private(set) var items: [Item] = []

    init(capacity: Int) { self.capacity = max(1, capacity) }

    var isEmpty: Bool { items.isEmpty }

    /// Adds `item` and returns the items dropped to make room.
    @discardableResult
    mutating func push(_ item: Item) -> [Item] {
        items.append(item)
        let excess = items.count - capacity
        guard excess > 0 else { return [] }
        let dropped = Array(items.prefix(excess))
        items.removeFirst(excess)
        return dropped
    }

    mutating func pop() -> Item? { items.isEmpty ? nil : items.removeFirst() }

    @discardableResult
    mutating func removeAll() -> [Item] {
        defer { items = [] }
        return items
    }
}
