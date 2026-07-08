import Foundation

/// App-wide settings, persisted to UserDefaults.
///
/// Only OpenRouter is supported today, but `provider` and the `LLMProvider`
/// protocol leave room to add Anthropic-direct, OpenAI, etc. later.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    enum Provider: String, CaseIterable, Identifiable {
        case openRouter = "OpenRouter"
        var id: String { rawValue }
    }

    @Published var provider: Provider {
        didSet { defaults.set(provider.rawValue, forKey: "provider") }
    }
    @Published var openRouterAPIKey: String {
        didSet { defaults.set(openRouterAPIKey, forKey: "openRouterAPIKey") }
    }
    /// OpenRouter model id, e.g. "anthropic/claude-opus-4-8".
    @Published var selectedModelID: String {
        didSet { defaults.set(selectedModelID, forKey: "selectedModelID") }
    }
    @Published var systemPrompt: String {
        didSet { defaults.set(systemPrompt, forKey: "systemPrompt") }
    }
    /// Optional: enables reference-photo comparison via pexels.com.
    @Published var pexelsAPIKey: String {
        didSet { defaults.set(pexelsAPIKey, forKey: "pexelsAPIKey") }
    }

    private let defaults = UserDefaults.standard

    private init() {
        provider = Provider(rawValue: defaults.string(forKey: "provider") ?? "") ?? .openRouter
        openRouterAPIKey = defaults.string(forKey: "openRouterAPIKey") ?? ""
        selectedModelID = defaults.string(forKey: "selectedModelID") ?? "openai/gpt-4o"
        systemPrompt = defaults.string(forKey: "systemPrompt") ?? AppSettings.defaultSystemPrompt
        pexelsAPIKey = defaults.string(forKey: "pexelsAPIKey") ?? ""
    }

    /// API key for the active provider.
    var activeAPIKey: String {
        switch provider {
        case .openRouter: return openRouterAPIKey
        }
    }

    static let defaultSystemPrompt = """
    You are a geolocation expert helping to restore missing GPS coordinates to \
    personal photographs. You work in an ongoing conversation with the user: they \
    show you a photo and share what they remember, and together you narrow down \
    where it was taken.

    Reason from evidence in the image: landmarks, architecture, signage and the \
    language on it, business names, license plates, road markings, vegetation, \
    terrain, coastline, sky, and the approximate capture date. Treat the user's \
    hints and corrections as strong signals — if they say it's Madrid in 1998 or \
    push back on your guess, take that seriously and reconsider.

    Be honest about uncertainty and about what specifically in the image supports \
    your answer. If it's a generic scene you can't place, say so. When the user \
    challenges or refines your guess, re-examine the image rather than just \
    agreeing.
    """

    /// Appended to the user's system prompt so replies are conversational *and*
    /// machine-parseable. Not user-editable — it guarantees the LOCATION line.
    static let conversationProtocol = """

    CONVERSATION PROTOCOL — follow exactly:
    - Reply conversationally and concisely (a short paragraph). Discuss the \
    evidence, respond to the user's hints and pushback, and ask a clarifying \
    question when it would genuinely help.
    - End EVERY reply with your current best answer on its own final line, in \
    exactly this format:
      LOCATION: {"place_name": "<specific, geocodable place>", "confidence": 0.0}
    - place_name must be specific enough for Apple Maps to find it, e.g. \
    "Puerta del Sol, Madrid, Spain". confidence is a number from 0.0 to 1.0.
    - If you genuinely cannot commit to a place yet, use exactly: LOCATION: none
    - Never put anything after the LOCATION line.
    """
}
