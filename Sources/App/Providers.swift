import Foundation

/// Builds the provider selected in the settings (or another one of the two, e.g. for watching the screen).
enum Providers {
    /// Whether a model service is set up, judged without reading the Keychain: a first read may ask for access, which
    /// must not block the main thread.
    static func configured(_ settings: AppSettings, kind: ProviderKind? = nil) -> Bool {
        switch kind ?? settings.provider {
        case .anthropic: return Keychain.hasValue(account: "anthropic")
        case .openai:
            let base = settings.openaiBaseURL
            return Keychain.hasValue(account: "openai") || base.contains("localhost") || base.contains("127.0.0.1")
        }
    }

    /// `current` with the key read off the main thread first (the Keychain may ask for access).
    static func currentInBackground(_ settings: AppSettings, kind: ProviderKind? = nil) async throws -> LLMProvider {
        let kind = kind ?? settings.provider
        _ = await Keychain.readInBackground(account: kind == .anthropic ? "anthropic" : "openai")
        return try current(settings, kind: kind)
    }

    static func current(_ settings: AppSettings, kind: ProviderKind? = nil) throws -> LLMProvider {
        switch kind ?? settings.provider {
        case .anthropic:
            guard let key = Keychain.read(account: "anthropic"), !key.isEmpty else { throw LLMError.missingKey }
            return AnthropicProvider(apiKey: key, model: settings.anthropicModel,
                                     serverFallback: settings.serverFallback)
        case .openai:
            let key = Keychain.read(account: "openai") ?? ""
            let local = settings.openaiBaseURL.contains("localhost") || settings.openaiBaseURL.contains("127.0.0.1")
            if key.isEmpty && !local { throw LLMError.missingKey }
            return OpenAICompatibleProvider(apiKey: key, baseURL: settings.openaiBaseURL, model: settings.openaiModel)
        }
    }
}
