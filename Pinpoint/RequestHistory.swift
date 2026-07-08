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

    /// Total OpenRouter cost logged since the start of today.
    var spentTodayUSD: Double {
        let start = Calendar.current.startOfDay(for: Date())
        return entries.filter { $0.date >= start }.compactMap(\.costUSD).reduce(0, +)
    }

    /// Total OpenRouter cost logged since the start of the current month.
    var spentMonthUSD: Double {
        let cal = Calendar.current
        let start = cal.date(from: cal.dateComponents([.year, .month], from: Date())) ?? Date()
        return entries.filter { $0.date >= start }.compactMap(\.costUSD).reduce(0, +)
    }

    /// Grand total across all logged requests.
    var totalUSD: Double {
        entries.compactMap(\.costUSD).reduce(0, +)
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
