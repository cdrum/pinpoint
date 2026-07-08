import SwiftUI

/// Settings, presented as a toolbar popover (360pt card) per the redesign.
struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var history = RequestHistory.shared

    @State private var models: [OpenRouterModel] = []
    @State private var loading = false
    @State private var loadError: String?
    @State private var selectedFamily = ""
    @State private var showPrompt = false

    private var families: [String] { Array(Set(models.map(\.family))).sorted() }
    private var modelsInFamily: [OpenRouterModel] {
        models.filter { $0.family == selectedFamily }.sorted { $0.name < $1.name }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings")
                .font(.system(size: 15, weight: .bold))
                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
            Divider().overlay(Theme.separatorLight)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    providerSection
                    modelSection
                    behaviorSection
                    referenceSection
                    promptSection
                }
                .padding(16)
            }

            Divider().overlay(Theme.separatorLight)
            spendFooter
        }
        .frame(width: 360, height: 560)
        .task { if models.isEmpty { await loadModels() } }
        .onChange(of: selectedFamily) {
            if !modelsInFamily.contains(where: { $0.id == settings.selectedModelID }),
               let first = modelsInFamily.first {
                settings.selectedModelID = first.id
            }
        }
    }

    // MARK: Sections

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel("OpenRouter API key")
            SecureField("sk-or-…", text: $settings.openRouterAPIKey)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
            Text("Get a key at openrouter.ai/keys. Stored in UserDefaults for this prototype.")
                .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
        }
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldLabel("Model")
            HStack {
                Text("Family").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                Spacer()
                if models.isEmpty {
                    Text("—").foregroundStyle(Theme.textSecondary)
                } else {
                    Picker("", selection: $selectedFamily) {
                        ForEach(families, id: \.self) { Text($0).tag($0) }
                    }.labelsHidden().frame(maxWidth: 200)
                }
            }
            HStack {
                Text("Model").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                Spacer()
                if modelsInFamily.isEmpty {
                    Text(settings.selectedModelID).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                } else {
                    Picker("", selection: $settings.selectedModelID) {
                        ForEach(modelsInFamily) { Text($0.name).tag($0.id) }
                    }.labelsHidden().frame(maxWidth: 200)
                }
            }
            HStack(spacing: 8) {
                Button { Task { await loadModels() } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise").font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .disabled(loading)
                if loading { ProgressView().controlSize(.small) }
                Spacer()
                Text("\(models.count) vision models").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
            }
            if let loadError {
                Text(loadError).font(.system(size: 11)).foregroundStyle(Theme.alert)
            }
        }
    }

    private var behaviorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            fieldLabel("Behavior")
            toggleRow("Auto-drop pin on answer", isOn: $settings.autoDropPin)
            toggleRow("Show reference photos", isOn: $settings.showReferences)
            toggleRow("Confirm before writing GPS", isOn: $settings.confirmBeforeWrite)
        }
    }

    private var referenceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel("Reference photos (Pexels API key)")
            SecureField("Optional — leave blank to disable", text: $settings.pexelsAPIKey)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
            Text("A free key from pexels.com/api shows stock photos of the guessed place.")
                .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
        }
    }

    private var promptSection: some View {
        DisclosureGroup(isExpanded: $showPrompt) {
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: $settings.systemPrompt)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(height: 140)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.separatorMedium))
                HStack {
                    Spacer()
                    Button("Reset to default") {
                        settings.systemPrompt = AppSettings.defaultSystemPrompt
                    }
                    .buttonStyle(.borderless).font(.system(size: 12))
                }
            }
            .padding(.top, 6)
        } label: {
            fieldLabel("System prompt")
        }
    }

    private var spendFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Monthly spend").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(spendText).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.textPrimary)
            }
            if settings.monthlyCapUSD > 0 {
                ConfidenceBar(value: history.spentMonthUSD / settings.monthlyCapUSD)
            }
            Stepper(value: $settings.monthlyCapUSD, in: 0...500, step: 5) {
                Text("Cap: \(settings.monthlyCapUSD == 0 ? "none" : String(format: "$%.0f", settings.monthlyCapUSD))")
                    .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var spendText: String {
        if settings.monthlyCapUSD > 0 {
            return String(format: "$%.2f / $%.2f", history.spentMonthUSD, settings.monthlyCapUSD)
        }
        return String(format: "$%.2f", history.spentMonthUSD)
    }

    // MARK: Helpers

    private func fieldLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.3)
            .foregroundStyle(Theme.textSecondary)
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title).font(.system(size: 13)).foregroundStyle(Theme.textPrimary)
        }
        .toggleStyle(.switch)
        .tint(Theme.success)
    }

    private func loadModels() async {
        loading = true; loadError = nil
        defer { loading = false }
        do {
            models = try await OpenRouterProvider.fetchVisionModels()
            let currentFamily = settings.selectedModelID.split(separator: "/").first.map(String.init) ?? ""
            selectedFamily = families.contains(currentFamily) ? currentFamily : (families.first ?? "")
        } catch {
            loadError = error.localizedDescription
        }
    }
}
