import SwiftUI

/// Recent requests, presented as a toolbar popover (340pt card) per the redesign.
struct HistoryView: View {
    @ObservedObject private var history = RequestHistory.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.separatorLight)

            if history.entries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock").font(.system(size: 28)).foregroundStyle(Theme.textQuaternary)
                    Text("No requests yet")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                    Text("Each location request is logged here with its cost.")
                        .font(.system(size: 11)).foregroundStyle(Theme.textQuaternary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 40).padding(.horizontal, 20)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(history.entries) { entry in
                            HistoryRow(entry: entry)
                            Divider().overlay(Theme.separatorLight).padding(.leading, 58)
                        }
                    }
                }
                .frame(maxHeight: 380)

                Divider().overlay(Theme.separatorLight)
                HStack {
                    Button(role: .destructive) { history.clear() } label: {
                        Label("Clear", systemImage: "trash").font(.system(size: 12))
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                    Text(String(format: "Total $%.2f", history.totalUSD))
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
        }
        .frame(width: 340)
    }

    private var header: some View {
        HStack {
            Text("Recent requests").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.textPrimary)
            Spacer()
            Text(String(format: "$%.2f today", history.spentTodayUSD))
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }
}

private struct HistoryRow: View {
    let entry: RequestLogEntry

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.thumbnail).fill(Theme.separatorMedium)
                Image(systemName: entry.success ? "photo" : "exclamationmark.triangle")
                    .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.success ? (entry.placeName ?? entry.photoFilename) : (entry.errorMessage ?? "Failed"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(entry.success ? Theme.textPrimary : Theme.alert)
                    .lineLimit(1)
                Text("\(shortModel(entry.model)) · \(relativeTime(entry.date))")
                    .font(.system(size: 11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(entry.costUSD.map { String(format: "$%.4f", $0) } ?? "—")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private func shortModel(_ id: String) -> String {
        id.split(separator: "/").last.map(String.init) ?? id
    }

    private func relativeTime(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}
