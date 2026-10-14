import Foundation

enum ProviderKind: String, Codable, CaseIterable, Identifiable {
    case anthropic, openai
    var id: String { rawValue }
    var title: String {
        switch self {
        case .anthropic: return "Claude (Anthropic)"
        case .openai: return tr("OpenAI 兼容接口", "OpenAI-compatible")
        }
    }
}

/// A client-side tool the model may call.
struct ToolSpec {
    var name: String
    var description: String
    /// JSON Schema of the input object.
    var schema: JSON
}

struct ToolCall {
    var id: String
    var name: String
    var input: JSON
}

struct ToolResult {
    var id: String
    var name: String
    var content: String
    var isError: Bool
}

struct Citation: Codable, Equatable, Hashable {
    var title: String
    var url: String
}

enum StopReason: Equatable {
    case end, toolUse, pauseTurn, maxTokens
    case other(String)
}

/// One model call, provider-neutral. `messages` are already in the provider's wire format
/// (built with the provider's `userMessage` / `assistantTextMessage` helpers or replayed verbatim).
struct LLMRequest {
    var system: String
    var messages: [JSON]
    var tools: [ToolSpec] = []
    /// Anthropic's server-side web search; ignored by other providers.
    var webSearch = false
    /// "low" … "max"; Anthropic only.
    var effort: String?
    var maxTokens: Int
    /// Structured output schema; OpenAI-compatible providers receive JSON mode instead.
    var jsonSchema: JSON? = nil
    /// Tools stay declared (the history may contain tool calls) but the model may not call them.
    var toolChoiceNone = false
}

enum LLMStreamEvent {
    case text(String)
    case status(String)
}

/// The outcome of one model call.
struct LLMTurn {
    /// Visible text of this response.
    var text: String
    var toolCalls: [ToolCall]
    var stopReason: StopReason
    /// The assistant message to append to the history, in wire format.
    var assistantMessage: JSON
    var citations: [Citation]
    var model: String?
}

protocol LLMProvider {
    var kind: ProviderKind { get }
    func send(_ request: LLMRequest, onEvent: @escaping (LLMStreamEvent) -> Void) async throws -> LLMTurn
    func userMessage(_ text: String) -> JSON
    func assistantTextMessage(_ text: String) -> JSON
    /// Messages carrying tool results (one user message for Anthropic, one `tool` message per result for OpenAI).
    func toolResultMessages(_ results: [ToolResult]) -> [JSON]
}

extension LLMProvider {
    /// A non-streaming-style convenience: sends and returns only the turn.
    func send(_ request: LLMRequest) async throws -> LLMTurn {
        try await send(request, onEvent: { _ in })
    }
}
