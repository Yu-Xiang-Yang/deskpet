import Foundation

enum AppLanguage {
    case zh, en
}

/// The language the user asked for; `auto` follows the first preferred system language.
enum LanguagePreference: String, CaseIterable, Identifiable {
    case auto, zh, en

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "自动 / Auto"
        case .zh: return "中文"
        case .en: return "English"
        }
    }
}

enum L10n {
    static var preference: LanguagePreference =
        LanguagePreference(rawValue: UserDefaults.standard.string(forKey: "language") ?? "") ?? .auto {
        didSet { UserDefaults.standard.set(preference.rawValue, forKey: "language") }
    }

    static var current: AppLanguage {
        switch preference {
        case .zh: return .zh
        case .en: return .en
        case .auto: return Locale.preferredLanguages.first?.hasPrefix("zh") == true ? .zh : .en
        }
    }

    static var locale: Locale { Locale(identifier: current == .zh ? "zh_CN" : "en_US") }

    static func time(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(locale))
    }

    static func dateTime(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
    }
}

/// Picks the Chinese or English text for the active language.
func tr(_ zh: String, _ en: String) -> String {
    L10n.current == .zh ? zh : en
}

enum AppPaths {
    /// ~/Library/Application Support/DeskPet
    /// The DESKPET_DIR environment variable overrides the location (used for testing).
    static var dataDir: URL {
        if let override = ProcessInfo.processInfo.environment["DESKPET_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DeskPet", isDirectory: true)
    }

    static var conversationsDir: URL { dataDir.appendingPathComponent("conversations", isDirectory: true) }
    /// Audio of the cloud voice kept on disk (CloudSpeechCache).
    static var voiceCacheDir: URL { dataDir.appendingPathComponent("voice-cache", isDirectory: true) }
    /// Still pictures of characters (not Live2D), e.g. the research-mode figure.
    static var charactersDir: URL { dataDir.appendingPathComponent("characters", isDirectory: true) }

    /// User-installed Live2D models; each subdirectory holds one model.
    static var userModelsDir: URL { dataDir.appendingPathComponent("models", isDirectory: true) }

    static func ensure(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
