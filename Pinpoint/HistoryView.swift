import SwiftUI

struct HistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var history = RequestHistory.shared

    var body: some View {
        VStack(spacing: 0) {
            if history.entries.isEmpty {
                ContentUnavailableView("No requests yet", systemImage: "clock",
                                       description: Text("Each location request is logged here with its result, tokens, and cost."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(history.entries) {
                    TableColumn("When") { Text($0.date.formatted(date: .abbreviated, time: .shortened)) }
                        .width(min: 130)
                    TableColumn("Photo", value: \.photoFilename).width(min: 120)
                    TableColumn("Model") { Text(shortModel($0.model)) }.width(min: 120)
                    TableColumn("Result") { entry in
                        if entry.success {
                            Text(entry.placeName ?? "—")
                        } else {
                            Text(entry.errorMessage ?? "failed").foregroundStyle(.red)
                        }
                    }
                    TableColumn("Conf") { entry in
                        Text(entry.confidence.map { "\(Int($0 * 100))%" } ?? "—")
                    }.width(50)
                    TableColumn("Tokens") { entry in
                        if let p = entry.promptTokens, let c = entry.completionTokens {
                            Text("\(p)/\(c)").monospacedDigit()
                        } else { Text("—") }
                    }.width(80)
                    TableColumn("Cost") { entry in
                        Text(entry.costUSD.map { String(format: "$%.4f", $0) } ?? "—").monospacedDigit()
                    }.width(80)
                }
            }

            Divider()
            HStack {
                Button(role: .destructive) { history.clear() } label: {
                    Label("Clear history", systemImage: "trash")
                }
                .disabled(history.entries.isEmpty)
                Spacer()
                if let total = totalCost {
                    Text("Total: \(String(format: "$%.4f", total))")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 820, height: 520)
    }

    private var totalCost: Double? {
        let costs = history.entries.compactMap { $0.costUSD }
        return costs.isEmpty ? nil : costs.reduce(0, +)
    }

    private func shortModel(_ id: String) -> String {
        id.split(separator: "/").last.map(String.init) ?? id
    }
}
