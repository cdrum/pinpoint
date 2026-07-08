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

    /// Which detail-pane direction from the redesign to show.
    /// - `conversation`: 2A — single vertical thread with a result card.
    /// - `inspector`: 2B — chat on the left, persistent map/location inspector.
    enum DetailLayout: String, CaseIterable, Identifiable {
        case conversation, inspector
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

    // MARK: - Behavior toggles

    /// Move the editable red pin to the geocoded answer automatically. When off,
    /// the answer still shows on the map but the user places the pin themselves.
    @Published var autoDropPin: Bool {
        didSet { defaults.set(autoDropPin, forKey: "autoDropPin") }
    }
    /// Show Pexels reference photos of the guessed place under the result card.
    @Published var showReferences: Bool {
        didSet { defaults.set(showReferences, forKey: "showReferences") }
    }
    /// Ask for confirmation before writing GPS back into a photo.
    @Published var confirmBeforeWrite: Bool {
        didSet { defaults.set(confirmBeforeWrite, forKey: "confirmBeforeWrite") }
    }
    /// Soft monthly spend cap (USD) shown as a budget meter. 0 = no cap.
    @Published var monthlyCapUSD: Double {
        didSet { defaults.set(monthlyCapUSD, forKey: "monthlyCapUSD") }
    }
    /// The detail-pane direction (2A conversation vs 2B inspector).
    @Published var detailLayout: DetailLayout {
        didSet { defaults.set(detailLayout.rawValue, forKey: "detailLayout") }
    }

    private let defaults = UserDefaults.standard

    private init() {
        provider = Provider(rawValue: defaults.string(forKey: "provider") ?? "") ?? .openRouter
        openRouterAPIKey = defaults.string(forKey: "openRouterAPIKey") ?? ""
        selectedModelID = defaults.string(forKey: "selectedModelID") ?? "openai/gpt-4o"
        systemPrompt = defaults.string(forKey: "systemPrompt") ?? AppSettings.defaultSystemPrompt
        pexelsAPIKey = defaults.string(forKey: "pexelsAPIKey") ?? ""
        // Defaults chosen to match the handoff mock (pin + references on, confirm off).
        autoDropPin = defaults.object(forKey: "autoDropPin") as? Bool ?? true
        showReferences = defaults.object(forKey: "showReferences") as? Bool ?? true
        confirmBeforeWrite = defaults.object(forKey: "confirmBeforeWrite") as? Bool ?? false
        monthlyCapUSD = defaults.object(forKey: "monthlyCapUSD") as? Double ?? 20
        detailLayout = DetailLayout(rawValue: defaults.string(forKey: "detailLayout") ?? "") ?? .inspector
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
