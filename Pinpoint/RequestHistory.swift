import Foundation

/// One logged geolocation request.
struct RequestLogEntry: Identifiable, Codable {
    let id: UUID
    let date: Date
    let photoFilename: String
    let model: String
    let userPrompt: String?
    let placeName: String?
    let confidence: Double?
    let promptTokens: Int?
    let completionTokens: Int?
    let costUSD: Double?
    let success: Bool
    let errorMessage: String?
}

/// Persists the request log to Application Support and publishes it to the UI.
@MainActor
final class RequestHistory: ObservableObject {
    static let shared = RequestHistory()

    @Published private(set) var entries: [RequestLogEntry] = []

    private let fileURL: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pinpoint", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("history.json")
        load()
    }

    /// Newest first, prepended, then persisted.
    func add(_ entry: RequestLogEntry) {
        entries.insert(entry, at: 0)
        save()
    }

    func clear() {
        entries = []
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([RequestLogEntry].self, from: data) else { return }
        entries = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
