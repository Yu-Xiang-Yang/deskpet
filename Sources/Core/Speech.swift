import CryptoKit
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

    /// Pieces of `text` for a speech service, each ending at a sentence end where possible: the first at most `first`
    /// characters, so that the voice starts soon, the others at most `size`. A sentence longer than that is split
    /// after a comma, otherwise at the limit.
    static func chunks(_ text: String, first: Int = 24, size: Int = 80) -> [String] {
        let ends: Set<Character> = ["。", "！", "？", "!", "?", "；", ";", "…"]
        var sentences: [String] = [], current = ""
        let chars = Array(text)
        for (i, c) in chars.enumerated() {
            current.append(c)
            let next = i + 1 < chars.count ? chars[i + 1] : nil
            let end = ends.contains(c) || (c == "." && (next == nil || next == " "))
            // Runs of closing marks ("！？", "……", "。”") stay with their sentence.
            if end, let next, ends.contains(next) || "”’）)」』\"".contains(next) { continue }
            if end || next == nil {
                let t = current.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { sentences.append(t) }
                current = ""
            }
        }
        var pieces: [String] = [], piece = ""
        func limit() -> Int { pieces.isEmpty ? first : size }
        for sentence in sentences {
            if !piece.isEmpty, piece.count + sentence.count > limit() {
                pieces.append(piece)
                piece = ""
            }
            piece += (piece.last?.isASCII == true ? " " : "") + sentence
            while piece.count > limit() {
                let chars = Array(piece), l = limit()
                let cut = (chars[..<l].lastIndex { "，,、：:".contains($0) }).map { $0 + 1 } ?? l
                pieces.append(String(chars[..<cut]).trimmingCharacters(in: .whitespaces))
                piece = String(chars[cut...]).trimmingCharacters(in: .whitespaces)
            }
        }
        if !piece.isEmpty { pieces.append(piece) }
        return pieces.filter { !$0.isEmpty }
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

    /// The service's explanation of a failed request (a JSON error or a short plain-text body), or the HTTP status.
    static func errorMessage(_ data: Data, status: Int) -> String {
        if let json = try? JSON.parse(data) {
            let message = json["error"]?["message"]?.string ?? json["error"]?.string ?? json["message"]?.string ?? json["detail"]?.string
            if let message, !message.isEmpty { return "HTTP \(status): \(message)" }
        } else if let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty, text.count <= 160, !text.hasPrefix("<") {
            return "HTTP \(status): \(text)"
        }
        return "HTTP \(status)"
    }
}

/// The local store of the cloud voice's audio (AppPaths.voiceCacheDir): each piece is kept under a name derived from
/// everything that decides its sound, so that what the pet says often is played from disk instead of being requested
/// (and paid for) again. Beyond `limit` bytes, the least recently used pieces go until 80% of it remain.
enum CloudSpeechCache {
    struct File: Equatable {
        var name: String
        var size: Int
        var used: Date
    }

    static let limit = 50 * 1024 * 1024

    /// SHA-256 of the service's host, model, voice, rate and text.
    static func name(text: String, model: String, voice: String, speed: Double, baseURL: String) -> String {
        let host = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased() ?? ""
        let fields = [host, model.trimmingCharacters(in: .whitespaces), voice.trimmingCharacters(in: .whitespaces),
                      String(format: "%.2f", speed), text]
        return SHA256.hash(data: Data(fields.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined() + ".mp3"
    }

    /// The files to delete so that the store fits: none while it is within `limit`.
    static func evictions(_ files: [File], limit: Int = limit) -> [String] {
        var total = files.reduce(0) { $0 + $1.size }
        guard total > limit else { return [] }
        var out: [String] = []
        for f in files.sorted(by: { $0.used < $1.used }) where total > limit * 4 / 5 {
            out.append(f.name)
            total -= f.size
        }
        return out
    }
}

/// The account balance behind a SiliconFlow key (`GET /v1/user/info`): the granted part ("balance") and the topped-up
/// part ("chargeBalance") make up the total ("totalBalance"); yuan on siliconflow.cn, dollars on siliconflow.com.
struct CloudSpeechBalance: Equatable {
    var total: Double
    var granted: Double
    var toppedUp: Double
    var currency: String
    var fetched: Date

    /// The balance endpoint on the host of a SiliconFlow base URL; nil for services without one (OpenAI and others).
    static func endpoint(baseURL: String) -> URL? {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)), let host = url.host?.lowercased(),
              host.hasSuffix("siliconflow.cn") || host.hasSuffix("siliconflow.com") else { return nil }
        var c = URLComponents()
        c.scheme = url.scheme ?? "https"
        c.host = host
        c.port = url.port
        c.path = "/v1/user/info"
        return c.url
    }

    /// "USD" on the international site (siliconflow.com), "CNY" otherwise.
    static func currency(baseURL: String) -> String {
        endpoint(baseURL: baseURL)?.host?.hasSuffix("siliconflow.com") == true ? "USD" : "CNY"
    }

    /// The SiliconFlow console of the same site, where the balance is topped up.
    static func console(baseURL: String) -> URL? {
        URL(string: currency(baseURL: baseURL) == "USD" ? "https://cloud.siliconflow.com" : "https://cloud.siliconflow.cn")
    }

    /// The balance in a `/v1/user/info` answer (amounts as strings or numbers); nil when there is none.
    static func parse(_ data: Data, currency: String, fetched: Date = Date()) -> CloudSpeechBalance? {
        guard let info = (try? JSON.parse(data))?["data"], info.object != nil else { return nil }
        func amount(_ key: String) -> Double? {
            info[key]?.string.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) } ?? info[key]?.double
        }
        let granted = amount("balance"), toppedUp = amount("chargeBalance")
        guard let total = amount("totalBalance") ?? granted.map({ $0 + (toppedUp ?? 0) }) ?? toppedUp else { return nil }
        return CloudSpeechBalance(total: total, granted: granted ?? 0, toppedUp: toppedUp ?? 0, currency: currency, fetched: fetched)
    }

    /// Whether the answer says the endpoint has been retired: SiliconFlow answers 410 ("This endpoint is deprecated",
    /// code 20092) since August 2026 and has named no replacement, so the balance is only shown in its console.
    static func retired(_ data: Data, status: Int) -> Bool {
        status == 410 || (try? JSON.parse(data))?["code"]?.int == 20092
    }

    /// "¥88.88".
    var short: String { DeepSeekBalance.money(total, currency) }

    /// "¥88.88（赠送 ¥0.88 · 充值 ¥88.00）".
    var detail: String {
        tr("\(short)（赠送 \(DeepSeekBalance.money(granted, currency)) · 充值 \(DeepSeekBalance.money(toppedUp, currency))）",
           "\(short) (granted \(DeepSeekBalance.money(granted, currency)) · topped up \(DeepSeekBalance.money(toppedUp, currency)))")
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
