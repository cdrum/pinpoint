import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                ProviderTab().tabItem { Label("Provider & Model", systemImage: "cpu") }
                PromptTab().tabItem { Label("System Prompt", systemImage: "text.alignleft") }
            }
            .padding()

            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 620, height: 520)
    }
}

// MARK: - Provider & model

private struct ProviderTab: View {
    @ObservedObject private var settings = AppSettings.shared

    @State private var models: [OpenRouterModel] = []
    @State private var loading = false
    @State private var loadError: String?
    @State private var selectedFamily = ""

    private var families: [String] {
        Array(Set(models.map(\.family))).sorted()
    }
    private var modelsInFamily: [OpenRouterModel] {
        models.filter { $0.family == selectedFamily }.sorted { $0.name < $1.name }
    }

    var body: some View {
        Form {
            Section {
                Picker("Provider", selection: $settings.provider) {
                    ForEach(AppSettings.Provider.allCases) { Text($0.rawValue).tag($0) }
                }
                SecureField("OpenRouter API key (sk-or-…)", text: $settings.openRouterAPIKey)
                Text("Get a key at openrouter.ai/keys. Stored in UserDefaults for this prototype — move to the Keychain before shipping.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Model") {
                HStack {
                    Text("Family")
                    Spacer()
                    if models.isEmpty {
                        Text("—").foregroundStyle(.secondary)
                    } else {
                        Picker("Family", selection: $selectedFamily) {
                            ForEach(families, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 260)
                    }
                }
                HStack {
                    Text("Model")
                    Spacer()
                    if modelsInFamily.isEmpty {
                        Text(settings.selectedModelID).foregroundStyle(.secondary)
                    } else {
                        Picker("Model", selection: $settings.selectedModelID) {
                            ForEach(modelsInFamily) { Text($0.name).tag($0.id) }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 260)
                    }
                }
                HStack {
                    Button {
                        Task { await loadModels() }
                    } label: {
                        Label("Refresh models", systemImage: "arrow.clockwise")
                    }
                    .disabled(loading)
                    if loading { ProgressView().controlSize(.small) }
                    if let loadError { Text(loadError).font(.caption).foregroundStyle(.red) }
                    Spacer()
                    Text("\(models.count) vision models").font(.caption).foregroundStyle(.secondary)
                }
                Text("Current: \(settings.selectedModelID)").font(.caption).foregroundStyle(.secondary)
            }

            Section("Reference photos (optional)") {
                SecureField("Pexels API key", text: $settings.pexelsAPIKey)
                Text("A free key from pexels.com/api shows stock photos of the guessed place so you can compare. Leave blank to disable.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { if models.isEmpty { await loadModels() } }
        .onChange(of: selectedFamily) {
            // Keep the selected model consistent with the chosen family.
            if !modelsInFamily.contains(where: { $0.id == settings.selectedModelID }),
               let first = modelsInFamily.first {
                settings.selectedModelID = first.id
            }
        }
    }

    private func loadModels() async {
        loading = true; loadError = nil
        defer { loading = false }
        do {
            models = try await OpenRouterProvider.fetchVisionModels()
            // Seed the family from the current selection (or the first available).
            let currentFamily = settings.selectedModelID.split(separator: "/").first.map(String.init) ?? ""
            selectedFamily = families.contains(currentFamily) ? currentFamily : (families.first ?? "")
        } catch {
            loadError = error.localizedDescription
        }
    }
}

// MARK: - System prompt

private struct PromptTab: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sent as the system prompt on every request. Your per-photo hints are added as the user message.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $settings.systemPrompt)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 300)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            HStack {
                Spacer()
                Button("Reset to default") {
                    settings.systemPrompt = AppSettings.defaultSystemPrompt
                }
            }
        }
    }
}
