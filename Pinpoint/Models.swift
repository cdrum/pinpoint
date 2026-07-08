import Foundation
import CoreLocation
import CoreGraphics
import Photos

/// A node in the album/folder tree shown in the sidebar.
///
/// - An **album** has a non-nil `album` and nil `children` (a leaf you can scan).
/// - A **folder** (or synthetic group) has nil `album` and non-nil `children`.
///   Selecting it scans every album nested underneath.
struct CollectionNode: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let album: PHAssetCollection?
    var children: [CollectionNode]?
}

/// A photo in the library, shown in the middle column.
struct PhotoItem: Identifiable {
    let id: String              // PHAsset.localIdentifier
    let creationDate: Date?
    var coordinate: CLLocationCoordinate2D?
    var thumbnail: CGImage?

    var hasLocation: Bool { coordinate != nil }
}

/// Running token/cost total for the current photo's conversation.
struct ConversationUsage {
    var promptTokens = 0
    var completionTokens = 0
    var costUSD = 0.0
    var hasCost = false
    var turns = 0

    mutating func add(_ usage: LLMUsage) {
        promptTokens += usage.promptTokens
        completionTokens += usage.completionTokens
        if let cost = usage.costUSD { costUSD += cost; hasCost = true }
        turns += 1
    }
}

/// One bubble in the conversation transcript shown in the UI.
struct ChatTurn: Identifiable {
    let id = UUID()
    let role: ChatRole
    let text: String
    /// Which model produced this reply (assistant turns only).
    var model: String? = nil
}

/// Which photos to show for the selected album.
enum LocationFilter: String, CaseIterable, Identifiable {
    case missing = "Missing location"
    case has = "Has location"
    case all = "All"

    var id: String { rawValue }
}

/// The result of asking the LLM where a photo was taken.
struct LocationGuess {
    /// Human-readable place, e.g. "Trevi Fountain, Rome, Italy".
    let placeName: String
    /// 0.0–1.0, the model's self-reported confidence.
    let confidence: Double
    /// One or two sentences explaining the visual cues used.
    let reasoning: String
    /// Coordinates, once geocoded (or provided directly by the model).
    var coordinate: CLLocationCoordinate2D?
}

/// Errors surfaced to the UI.
enum PinpointError: LocalizedError {
    case noAPIKey
    case badResponse(String)
    case couldNotGeocode(String)
    case photosScript(String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "No OpenRouter API key set. Add one in Settings."
        case .badResponse(let detail):
            return "The model response could not be parsed: \(detail)"
        case .couldNotGeocode(let place):
            return "Couldn't turn \"\(place)\" into coordinates."
        case .photosScript(let detail):
            return "Couldn't reach the Photos app: \(detail)"
        }
    }
}
