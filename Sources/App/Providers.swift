import Foundation

/// Builds the provider selected in the settings.
enum Providers {
    static func current(_ settings: AppSettings) throws -> LLMProvider {
        switch settings.provider {
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
