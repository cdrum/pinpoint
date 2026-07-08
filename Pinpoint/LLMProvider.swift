import Foundation

enum ChatRole: String {
    case system, user, assistant
}

/// One message in the conversation. The photo is attached to the first user
/// turn via `imageJPEG`; later turns are text-only.
struct ChatMessage {
    let role: ChatRole
    let text: String
    var imageJPEG: Data? = nil
}

/// Token accounting returned by the provider.
struct LLMUsage {
    let promptTokens: Int
    let completionTokens: Int
    let costUSD: Double?
}

/// Raw provider response (still needs LOCATION extraction + geocoding).
struct LLMResponse {
    let rawText: String
    let usage: LLMUsage?
}

/// One event from a streaming reply: an incremental text delta, or the final
/// token/cost accounting emitted once the stream completes.
enum LLMStreamChunk {
    case delta(String)
    case done(LLMUsage?)
}

/// A pluggable LLM backend. OpenRouter is the only implementation today;
/// add Anthropic-direct / OpenAI / etc. by conforming new types.
protocol LLMProvider {
    /// Multi-turn vision chat: system prompt + conversation → assistant reply.
    func chat(system: String,
              messages: [ChatMessage],
              model: String,
              apiKey: String) async throws -> LLMResponse

    /// Streaming variant: yields text deltas as they arrive, then a final
    /// `.done` with usage. Consumers accumulate the deltas into the reply.
    func chatStream(system: String,
                    messages: [ChatMessage],
                    model: String,
                    apiKey: String) -> AsyncThrowingStream<LLMStreamChunk, Error>
}
