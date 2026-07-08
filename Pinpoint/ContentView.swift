import SwiftUI
import Photos
import CoreLocation
import MapKit
import AppKit

@MainActor
final class ViewModel: ObservableObject {
    /// Where the detail pane is in the ask → answer → write lifecycle.
    enum Phase { case idle, thinking, streaming, answered, writing }

    @Published var status: PHAuthorizationStatus = .notDetermined
    @Published var collections: [CollectionNode] = []
    @Published var selectedCollectionID: String?
    @Published var filter: LocationFilter = .missing
    @Published var items: [PhotoItem] = []
    @Published var selectedID: String?
    @Published var isLoading = false

    // Conversation
    @Published var transcript: [ChatTurn] = []
    @Published var chatInput: String = ""
    @Published var phase: Phase = .idle

    // Current extracted location
    @Published var guess: LocationGuess?
    @Published var usage = ConversationUsage()   // running total for this photo
    @Published var editableCoordinate: CLLocationCoordinate2D?
    @Published var referencePhotos: [PexelsPhoto] = []
    @Published var isLoadingReferences = false
    @Published var message: String?
    /// Bumped only when a new guess moves the pin, so the map re-frames then
    /// (but not on every drag tick).
    @Published var mapFramingToken = 0
    /// A copied coordinate that can be stamped onto other photos.
    @Published var copiedCoordinate: CLLocationCoordinate2D?
    /// Drives the "Confirm before writing GPS" dialog.
    @Published var confirmingWrite = false

    private let library = PhotoLibraryService()
    private let provider: LLMProvider = OpenRouterProvider()
    private let settings = AppSettings.shared
    private let history = RequestHistory.shared
    private var assetsByID: [String: PHAsset] = [:]
    private var nodesByID: [String: CollectionNode] = [:]

    private var conversation: [ChatMessage] = []   // full API history (image on first turn)
    private var currentJPEG: Data?

    var selectedAsset: PHAsset? { selectedID.flatMap { assetsByID[$0] } }
    var selectedItem: PhotoItem? { items.first { $0.id == selectedID } }

    /// Original filename (e.g. "IMG_2098.jpg") for the 2B chat header.
    var selectedFilename: String? { selectedAsset.map { library.filename(for: $0) } }
    /// The selected album/folder's title, for the 2B chat header subtitle.
    var selectedAlbumTitle: String? { selectedCollectionID.flatMap { nodesByID[$0]?.title } }

    /// A request is in flight (before or during the streamed reply).
    var isBusy: Bool { phase == .thinking || phase == .streaming }

    /// The coordinate the "Set photo location" button will write. When
    /// auto-drop-pin is off the user must place the pin themselves.
    var writeCoordinate: CLLocationCoordinate2D? {
        editableCoordinate ?? (settings.autoDropPin ? guess?.coordinate : nil)
    }

    // MARK: - Loading

    func start() async {
        status = await library.requestAuthorization()
        guard status == .authorized || status == .limited else { return }
        collections = library.fetchCollectionTree()
        nodesByID = [:]
        indexNodes(collections)
    }

    private func indexNodes(_ nodes: [CollectionNode]) {
        for node in nodes {
            nodesByID[node.id] = node
            if let children = node.children { indexNodes(children) }
        }
    }

    func reloadPhotos() async {
        resetPhotoState()
        selectedID = nil
        items = []; assetsByID = [:]
        guard let id = selectedCollectionID, let node = nodesByID[id] else { return }

        isLoading = true
        defer { isLoading = false }

        let assets = library.fetchPhotos(in: node, filter: filter)
        assetsByID = Dictionary(uniqueKeysWithValues: assets.map { ($0.localIdentifier, $0) })
        items = assets.map {
            PhotoItem(id: $0.localIdentifier, creationDate: $0.creationDate,
                      coordinate: $0.location?.coordinate, thumbnail: nil)
        }
        for asset in assets {
            let thumb = await library.thumbnail(for: asset)
            if let idx = items.firstIndex(where: { $0.id == asset.localIdentifier }) {
                items[idx].thumbnail = thumb
            }
        }
    }

    func photoSelectionChanged() {
        resetPhotoState()
        editableCoordinate = selectedItem?.coordinate
    }

    private func resetPhotoState() {
        transcript = []; conversation = []; chatInput = ""; currentJPEG = nil
        guess = nil; usage = ConversationUsage(); message = nil
        referencePhotos = []; editableCoordinate = nil; phase = .idle
    }

    // MARK: - Conversation

    func sendChat() async {
        guard let asset = selectedAsset else { return }
        let isFirstTurn = conversation.isEmpty
        let typed = chatInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let userText = typed.isEmpty
            ? (isFirstTurn ? "Where do you think this photo was taken?" : "")
            : typed
        guard !userText.isEmpty else { return }

        guard !settings.activeAPIKey.trimmingCharacters(in: .whitespaces).isEmpty else {
            message = PinpointError.noAPIKey.errorDescription
            return
        }

        message = nil
        phase = .thinking

        // Attach the image on the first user turn only.
        var imageData: Data?
        if isFirstTurn {
            guard let jpeg = await library.jpegForAnalysis(asset) else {
                message = "Couldn't load full-size image."
                phase = .idle
                return
            }
            currentJPEG = jpeg
            imageData = jpeg
        }

        // Optimistically show the user's message.
        chatInput = ""
        transcript.append(ChatTurn(role: .user, text: userText))
        conversation.append(ChatMessage(role: .user, text: userText, imageJPEG: imageData))

        let system = settings.systemPrompt + "\n" + AppSettings.conversationProtocol

        var raw = ""
        var assistantIndex: Int?
        var finalUsage: LLMUsage?
        do {
            let stream = provider.chatStream(system: system, messages: conversation,
                                             model: settings.selectedModelID,
                                             apiKey: settings.activeAPIKey)
            for try await chunk in stream {
                switch chunk {
                case .delta(let text):
                    raw += text
                    let display = LocationParsing.displayPortion(of: raw)
                    if let idx = assistantIndex {
                        transcript[idx].text = display
                    } else {
                        transcript.append(ChatTurn(role: .assistant, text: display,
                                                   model: settings.selectedModelID))
                        assistantIndex = transcript.count - 1
                        phase = .streaming
                    }
                case .done(let u):
                    finalUsage = u
                }
            }
        } catch {
            // Roll back the optimistic turns so a retry is clean.
            if let idx = assistantIndex { transcript.remove(at: idx) }
            transcript.removeLast()          // the user turn
            conversation.removeLast()        // the user message
            chatInput = userText
            if isFirstTurn { currentJPEG = nil }
            phase = .idle
            message = error.localizedDescription
            logTurn(asset: asset, userText: userText, place: nil, confidence: nil,
                    usage: nil, success: false, error: error.localizedDescription)
            return
        }

        // Finalize the assistant turn.
        let extraction = LocationParsing.extract(from: raw)
        let display = extraction.display.isEmpty ? raw : extraction.display
        if let idx = assistantIndex {
            transcript[idx].text = display
            transcript[idx].tokensIn = finalUsage?.promptTokens
            transcript[idx].tokensOut = finalUsage?.completionTokens
            transcript[idx].costUSD = finalUsage?.costUSD
        } else {
            transcript.append(ChatTurn(role: .assistant, text: display,
                                       model: settings.selectedModelID,
                                       tokensIn: finalUsage?.promptTokens,
                                       tokensOut: finalUsage?.completionTokens,
                                       costUSD: finalUsage?.costUSD))
        }
        conversation.append(ChatMessage(role: .assistant, text: raw))
        if let u = finalUsage { usage.add(u) }

        if let place = extraction.placeName {
            let changed = (guess?.placeName != place)
            guess = LocationGuess(placeName: place, confidence: extraction.confidence,
                                  reasoning: display, coordinate: guess?.coordinate)
            if changed {
                // A new place was agreed on — re-geocode and re-fetch references.
                if let coord = await Geocoding.resolve(place) {
                    guess?.coordinate = coord
                    if settings.autoDropPin { editableCoordinate = coord }
                    mapFramingToken += 1   // re-frame the map to show the new pin
                }
                if settings.showReferences {
                    await loadReferences(for: place)
                } else {
                    referencePhotos = []
                }
            }
        }

        phase = .answered
        logTurn(asset: asset, userText: userText, place: extraction.placeName,
                confidence: extraction.placeName == nil ? nil : extraction.confidence,
                usage: finalUsage, success: true, error: nil)
    }

    private func logTurn(asset: PHAsset, userText: String, place: String?, confidence: Double?,
                         usage: LLMUsage?, success: Bool, error: String?) {
        history.add(RequestLogEntry(id: UUID(), date: Date(),
                                    photoFilename: library.filename(for: asset),
                                    model: settings.selectedModelID, userPrompt: userText,
                                    placeName: place, confidence: confidence,
                                    promptTokens: usage?.promptTokens,
                                    completionTokens: usage?.completionTokens,
                                    costUSD: usage?.costUSD, success: success, errorMessage: error))
    }

    // MARK: - References & write

    private func loadReferences(for placeName: String) async {
        referencePhotos = []
        let key = settings.pexelsAPIKey
        guard !key.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isLoadingReferences = true
        defer { isLoadingReferences = false }
        referencePhotos = (try? await PexelsProvider.search(placeName, apiKey: key)) ?? []
    }

    /// Write an assistant message as the photo's Caption (scripts Photos).
    func setDescription(_ text: String) async {
        guard let asset = selectedAsset else { return }
        do {
            try await library.setDescription(text, for: asset)
            message = "Description written to photo. ✓"
        } catch {
            message = error.localizedDescription
        }
    }

    /// Entry point for the "Set photo location" button — routes through a
    /// confirmation dialog first when that setting is enabled.
    func requestWriteLocation() {
        guard writeCoordinate != nil else { return }
        if settings.confirmBeforeWrite {
            confirmingWrite = true
        } else {
            Task { await performWrite() }
        }
    }

    func performWrite() async {
        guard let id = selectedID, let coordinate = writeCoordinate else { return }
        phase = .writing
        await applyLocation(coordinate, to: id, successMessage: "Location written. ✓")
        if phase == .writing { phase = .answered }
    }

    /// Copy "lat, lng" to the system clipboard.
    func copyCoordinateToPasteboard() {
        guard let c = writeCoordinate ?? selectedItem?.coordinate else { return }
        let s = String(format: "%.5f, %.5f", c.latitude, c.longitude)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        message = "Copied \(s)"
    }

    // MARK: Cross-photo stamp (row context menu)

    /// Copy the selected photo's location so it can be stamped onto other photos.
    func copyLocation(id: String) {
        copiedCoordinate = assetsByID[id]?.location?.coordinate
            ?? items.first { $0.id == id }?.coordinate
        message = copiedCoordinate == nil ? "Nothing to copy." : "Location copied — paste it onto other photos."
    }

    func pasteLocation(to id: String) async {
        guard let coordinate = copiedCoordinate else { return }
        await applyLocation(coordinate, to: id, successMessage: "Location pasted. ✓")
    }

    func removeLocation(id: String) async {
        guard let asset = assetsByID[id] else { return }
        do {
            try await library.removeLocation(from: asset)
            if let idx = items.firstIndex(where: { $0.id == id }) { items[idx].coordinate = nil }
            if filter == .has { dropFromList(id) }   // no longer matches "Has location"
            message = "Location removed. ✓"
        } catch {
            message = "Remove failed: \(error.localizedDescription)"
        }
    }

    /// Shared writer used by Set / Paste — updates the list to match the filter.
    private func applyLocation(_ coordinate: CLLocationCoordinate2D, to id: String, successMessage: String) async {
        guard let asset = assetsByID[id] else { return }
        do {
            try await library.writeLocation(coordinate, to: asset)
            if filter == .missing {
                dropFromList(id, forget: true)   // no longer matches "Missing location"
            } else if let idx = items.firstIndex(where: { $0.id == id }) {
                items[idx].coordinate = coordinate
            }
            message = successMessage
        } catch {
            message = "Write failed: \(error.localizedDescription)"
        }
    }

    /// Remove a row that no longer matches the filter, auto-advancing selection
    /// to the next (or previous) photo so the workflow keeps flowing.
    private func dropFromList(_ id: String, forget: Bool = false) {
        let wasSelected = (selectedID == id)
        let next = wasSelected ? neighborID(of: id) : selectedID
        items.removeAll { $0.id == id }
        if forget { assetsByID[id] = nil }
        if wasSelected { selectedID = next }
    }

    /// The photo to select after `id` leaves the list: the next row, else the previous.
    private func neighborID(of id: String) -> String? {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return nil }
        if idx + 1 < items.count { return items[idx + 1].id }
        if idx - 1 >= 0 { return items[idx - 1].id }
        return nil
    }
}

// MARK: - Shell

struct ContentView: View {
    @StateObject private var vm = ViewModel()
    @ObservedObject private var settings = AppSettings.shared
    @State private var showingSettings = false
    @State private var showingHistory = false

    var body: some View {
        NavigationSplitView {
            SidebarView(vm: vm)
                .navigationSplitViewColumnWidth(min: 220, ideal: 236, max: 300)
        } content: {
            PhotoListView(vm: vm)
                .navigationSplitViewColumnWidth(min: 296, ideal: 300, max: 340)
        } detail: {
            DetailView(vm: vm)
        }
        .navigationTitle("Photos")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("Layout", selection: $settings.detailLayout) {
                    Image(systemName: "bubble.left.and.text.bubble.right")
                        .tag(AppSettings.DetailLayout.conversation)
                    Image(systemName: "sidebar.trailing")
                        .tag(AppSettings.DetailLayout.inspector)
                }
                .pickerStyle(.segmented)
                .help("Switch between conversation and inspector layouts")

                Button { showingHistory.toggle() } label: {
                    Image(systemName: "clock")
                }
                .help("Recent requests")
                .popover(isPresented: $showingHistory, arrowEdge: .bottom) {
                    HistoryView()
                }

                Button { showingSettings.toggle() } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .help("Settings")
                .popover(isPresented: $showingSettings, arrowEdge: .bottom) {
                    SettingsView()
                }
            }
        }
        .toolbarBackground(Theme.toolbarBg, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .task { await vm.start() }
        .onChange(of: vm.selectedCollectionID) { Task { await vm.reloadPhotos() } }
        .onChange(of: vm.filter) { Task { await vm.reloadPhotos() } }
        .onChange(of: vm.selectedID) { vm.photoSelectionChanged() }
    }
}

// MARK: - Column 1: sidebar

struct SidebarView: View {
    @ObservedObject var vm: ViewModel

    var body: some View {
        Group {
            if vm.status != .authorized && vm.status != .limited {
                ContentUnavailableView("Photo access needed", systemImage: "lock",
                                       description: Text("Grant access in System Settings › Privacy › Photos, then reopen."))
            } else {
                List(selection: $vm.selectedCollectionID) {
                    OutlineGroup(vm.collections, children: \.children) { node in
                        Label(node.title, systemImage: node.systemImage)
                            .font(.system(size: 13))
                            .tag(node.id)
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .background(Theme.sidebarBg)
            }
        }
        .background(Theme.sidebarBg)
        .navigationTitle("Library")
    }
}

// MARK: - Column 2: photo list

struct PhotoListView: View {
    @ObservedObject var vm: ViewModel

    var body: some View {
        VStack(spacing: 0) {
            FilterSegmentedControl(selection: $vm.filter)
                .padding(10)
            Divider().overlay(Theme.separatorLight)
            list
        }
        .background(Theme.contentBg)
        .navigationTitle("Photos")
    }

    @ViewBuilder
    private var list: some View {
        if vm.selectedCollectionID == nil {
            centered("Pick an album", "rectangle.stack")
        } else if vm.isLoading {
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Scanning…").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if vm.items.isEmpty {
            centered(emptyTitle, "photo.on.rectangle.angled")
        } else {
            List(vm.items, selection: $vm.selectedID) { item in
                PhotoRow(item: item)
                    .tag(item.id)
                    .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                    .contextMenu { rowMenu(for: item) }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .background(Theme.contentBg)
        }
    }

    @ViewBuilder
    private func rowMenu(for item: PhotoItem) -> some View {
        Button("Copy location to stamp") { vm.copyLocation(id: item.id) }
            .disabled(!item.hasLocation)
        if vm.copiedCoordinate != nil {
            Button("Paste copied location") { Task { await vm.pasteLocation(to: item.id) } }
        }
        if item.hasLocation {
            Divider()
            Button("Remove location", role: .destructive) { Task { await vm.removeLocation(id: item.id) } }
        }
    }

    private func centered(_ title: String, _ symbol: String) -> some View {
        ContentUnavailableView(title, systemImage: symbol)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.contentBg)
    }

    private var emptyTitle: String {
        switch vm.filter {
        case .missing: return "No photos missing location"
        case .has: return "No photos with location"
        case .all: return "No photos"
        }
    }
}

/// A single photo list row: 44×44 thumbnail + date + location status line.
struct PhotoRow: View {
    let item: PhotoItem

    var body: some View {
        HStack(spacing: 11) {
            thumbnail
            VStack(alignment: .leading, spacing: 2) {
                Text(dateText)
                    .font(.system(size: 13, weight: .semibold))
                HStack(spacing: 4) {
                    Image(systemName: item.hasLocation ? "mappin.circle.fill" : "mappin.slash")
                        .font(.system(size: 11))
                    Text(item.hasLocation ? "Located" : "No location")
                        .font(.system(size: 12))
                }
                .foregroundStyle(item.hasLocation ? Theme.accent : Theme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private var thumbnail: some View {
        Group {
            if let cg = item.thumbnail {
                Image(decorative: cg, scale: 1).resizable().scaledToFill()
            } else {
                Theme.separatorMedium
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.thumbnail))
    }

    private var dateText: String {
        item.creationDate.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "Unknown date"
    }
}

/// Custom 3-segment filter matching the handoff (blue active segment).
struct FilterSegmentedControl: View {
    @Binding var selection: LocationFilter

    var body: some View {
        HStack(spacing: 0) {
            ForEach(LocationFilter.allCases) { option in
                let active = option == selection
                Text(option.rawValue)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(active ? .white : Theme.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(active ? Theme.accent : .clear,
                                in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                    .onTapGesture { selection = option }
            }
        }
        .padding(2)
        .background(Theme.segmentTrack, in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Column 3/4: detail — dispatches on the chosen layout direction

struct DetailView: View {
    @ObservedObject var vm: ViewModel
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Group {
            if vm.selectedItem == nil {
                EmptyStateView()
            } else if settings.detailLayout == .inspector {
                InspectorLayout(vm: vm)          // Direction 2B
            } else {
                ConversationLayout(vm: vm)       // Direction 2A
            }
        }
        .background(Theme.contentBg)
        .confirmationDialog("Write this location into the photo?",
                            isPresented: $vm.confirmingWrite, titleVisibility: .visible) {
            Button("Set photo location") { Task { await vm.performWrite() } }
            Button("Cancel", role: .cancel) { }
        } message: {
            if let c = vm.writeCoordinate {
                Text(String(format: "%.5f, %.5f will be saved to this photo's metadata.", c.latitude, c.longitude))
            }
        }
    }
}

// MARK: Direction 2A — conversation-first (single vertical thread + result card)

struct ConversationLayout: View {
    @ObservedObject var vm: ViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .center, spacing: 18) {
                if let cg = vm.selectedItem?.thumbnail {
                    HeroPhoto(image: cg)
                }

                ChatThread(vm: vm)
                ComposerView(vm: vm)

                if vm.guess != nil || vm.selectedItem?.hasLocation == true {
                    ResultCard(vm: vm)
                }

                if let message = vm.message {
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 26)
            .padding(.vertical, 22)
        }
    }
}

// MARK: Direction 2B — chat column + persistent location inspector

struct InspectorLayout: View {
    @ObservedObject var vm: ViewModel

    var body: some View {
        HStack(spacing: 0) {
            ChatColumn(vm: vm)
                .frame(maxWidth: .infinity)
            Rectangle().fill(Theme.separatorMedium).frame(width: 1)
            InspectorColumn(vm: vm)
                .frame(width: 392)
        }
    }
}

/// 2B left column: photo/status header, scrolling thread, pinned composer.
struct ChatColumn: View {
    @ObservedObject var vm: ViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.separatorLight).frame(height: 1)
            ScrollView {
                VStack(spacing: 14) {
                    ChatThread(vm: vm)
                    if let message = vm.message {
                        Text(message)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
            }
            Rectangle().fill(Theme.separatorLight).frame(height: 1)
            ComposerView(vm: vm)
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
        }
        .background(Theme.contentBg)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Group {
                if let cg = vm.selectedItem?.thumbnail {
                    Image(decorative: cg, scale: 1).resizable().scaledToFill()
                } else {
                    Theme.separatorMedium
                }
            }
            .frame(width: 150, height: 104)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(vm.selectedFilename ?? "Photo")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                statusLabel
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var subtitle: String {
        let date = vm.selectedItem?.creationDate.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "Unknown date"
        if let album = vm.selectedAlbumTitle { return "\(date) · \(album)" }
        return date
    }

    @ViewBuilder
    private var statusLabel: some View {
        let located = vm.selectedItem?.hasLocation == true
        HStack(spacing: 5) {
            Image(systemName: located ? "mappin.circle.fill" : "mappin.slash")
                .font(.system(size: 12))
            Text(located ? "Located" : "No location yet")
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(located ? Theme.success : Theme.warning)
        .padding(.top, 2)
    }
}

/// 2B right column: the persistent suggested-location inspector.
struct InspectorColumn: View {
    @ObservedObject var vm: ViewModel

    /// Show the map whenever we have a model guess OR the photo already has a
    /// saved location — so a located photo plots immediately.
    private var hasLocation: Bool { vm.guess != nil || vm.selectedItem?.hasLocation == true }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(vm.guess != nil ? "SUGGESTED LOCATION" : "SAVED LOCATION")
                    .font(.system(size: 11, weight: .semibold)).tracking(0.3)
                    .foregroundStyle(Theme.textSecondary)

                if hasLocation {
                    if let guess = vm.guess {
                        placeHeader(guess)
                        ConfidenceBar(value: guess.confidence)
                    }
                    SuggestedMap(current: vm.guess == nil ? nil : vm.selectedItem?.coordinate,
                                 suggestion: vm.guess?.coordinate,
                                 editable: $vm.editableCoordinate,
                                 framingToken: vm.mapFramingToken,
                                 identity: vm.selectedID ?? "")
                        .frame(height: 236)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.map))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.map).stroke(Theme.separatorMedium, lineWidth: 1))

                    coords
                    actions

                    if vm.isLoadingReferences || !vm.referencePhotos.isEmpty {
                        Rectangle().fill(Theme.separatorLight).frame(height: 1).padding(.vertical, 2)
                        references
                    }
                } else {
                    placeholder
                }
            }
            .padding(18)
        }
        .background(Theme.inspectorBg)
    }

    private func placeHeader(_ guess: LocationGuess) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Theme.alert).frame(width: 22, height: 22)
                Image(systemName: "exclamationmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
            }
            Text(guess.placeName)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Text("\(Int(guess.confidence * 100))%")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var coords: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let c = vm.writeCoordinate {
                Text(String(format: "%.5f, %.5f", c.latitude, c.longitude))
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
            } else {
                Text("Tap the map to place the pin")
                    .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
            }
            Text("Tap the map or drag the pin to adjust")
                .font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button {
                vm.requestWriteLocation()
            } label: {
                if vm.phase == .writing {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                } else {
                    Text("Set photo location").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.pinpointPrimary)
            .disabled(vm.writeCoordinate == nil || vm.phase == .writing)

            Button("Copy") { vm.copyCoordinateToPasteboard() }
                .buttonStyle(.pinpointSecondary)
                .disabled(vm.writeCoordinate == nil && vm.selectedItem?.hasLocation != true)
        }
    }

    private var references: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("REFERENCE PHOTOS · via Pexels")
                .font(.system(size: 11, weight: .semibold)).tracking(0.3)
                .foregroundStyle(Theme.textSecondary)
            if vm.isLoadingReferences {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading…").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                    GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(vm.referencePhotos) { ReferenceGridThumb(photo: $0) }
                }
            }
        }
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "mappin.slash")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.textQuaternary)
            Text("No suggestion yet")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
            Text("Ask the model where this was taken to see a location here.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textQuaternary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }
}

/// A flexible-width reference thumbnail for the 2B inspector's 2-column grid.
struct ReferenceGridThumb: View {
    let photo: PexelsPhoto
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button { openURL(photo.pageURL) } label: {
            VStack(alignment: .leading, spacing: 3) {
                AsyncImage(url: photo.thumbURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    ZStack { Theme.separatorMedium; ProgressView().controlSize(.small) }
                }
                .frame(height: 82)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.reference))
                Text(photo.photographer)
                    .font(.system(size: 10.5)).foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }
}

struct HeroPhoto: View {
    let image: CGImage
    var body: some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .scaledToFill()
            .frame(width: 340, height: 230)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
    }
}

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Theme.textQuaternary)
            Text("Select a photo")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
            Text("Pick a photo from the list to ask where it was taken")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textQuaternary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.contentBg)
    }
}

// MARK: Conversation thread

struct ChatThread: View {
    @ObservedObject var vm: ViewModel

    var body: some View {
        VStack(spacing: 14) {
            if vm.transcript.isEmpty && vm.phase == .idle {
                Text("Ask where this was taken — add any hints (place, year, landmarks).")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(vm.transcript) { turn in
                ChatBubbleView(turn: turn,
                               onSetDescription: turn.role == .assistant
                                   ? { Task { await vm.setDescription(turn.text) } }
                                   : nil)
            }
            if vm.phase == .thinking {
                TypingBubble()
            }
        }
    }
}

/// A message bubble. User right-aligned (blue), assistant left (grey) with a
/// meta row carrying the "Set as description" action, model, and token/cost.
struct ChatBubbleView: View {
    let turn: ChatTurn
    var onSetDescription: (() -> Void)?

    private var isUser: Bool { turn.role == .user }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 60) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
                Text(turn.text.isEmpty ? " " : turn.text)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.bubbleText)
                    .textSelection(.enabled)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 14)
                    .background(isUser ? Theme.userBubble : Theme.assistantBubble,
                                in: BubbleShape(isUser: isUser))
                if !isUser { metaRow }
            }
            if !isUser { Spacer(minLength: 60) }
        }
    }

    @ViewBuilder
    private var metaRow: some View {
        HStack(spacing: 14) {
            if let onSetDescription {
                Button(action: onSetDescription) {
                    Label("Set as description", systemImage: "doc.text")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
            }
            if let model = turn.model {
                HStack(spacing: 5) {
                    Circle().fill(Theme.success).frame(width: 6, height: 6)
                    Text(model).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
            }
            if let tin = turn.tokensIn, let tout = turn.tokensOut {
                Text(tokenLine(tin, tout, turn.costUSD))
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func tokenLine(_ tin: Int, _ tout: Int, _ cost: Double?) -> String {
        var s = "\(tin) in · \(tout) out"
        if let cost { s += String(format: " · $%.4f", cost) }
        return s
    }
}

/// Per-corner rounded bubble with a 4px tail corner (bottom-trailing for the
/// user, bottom-leading for the assistant).
struct BubbleShape: InsettableShape {
    var isUser: Bool
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = Theme.Radius.bubble
        let tail = Theme.Radius.bubbleTail
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: r,
            bottomLeadingRadius: isUser ? r : tail,
            bottomTrailingRadius: isUser ? tail : r,
            topTrailingRadius: r,
            style: .continuous)
        return shape.path(in: rect.insetBy(dx: inset, dy: inset))
    }

    func inset(by amount: CGFloat) -> some InsettableShape {
        var copy = self; copy.inset += amount; return copy
    }
}

/// The assistant "typing" bubble: three dots pulsing on a staggered loop.
struct TypingBubble: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Color(hex: 0x8E8E93))
                        .frame(width: 7, height: 7)
                        .opacity(animating ? 1 : 0.3)
                        .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.2), value: animating)
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .background(Theme.assistantBubble, in: BubbleShape(isUser: false))

            Text("Analyzing the photo · geocoding the answer")
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 20)
        }
        .onAppear { animating = true }
    }
}

// MARK: Composer

struct ComposerView: View {
    @ObservedObject var vm: ViewModel
    @FocusState private var focused: Bool

    private var isFirst: Bool { vm.transcript.isEmpty }

    var body: some View {
        HStack(spacing: 10) {
            TextField(isFirst ? "Ask where this was taken — add any hints"
                              : "Reply — confirm, correct, or ask a question",
                      text: $vm.chatInput, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(1...4)
                .focused($focused)
                .padding(.horizontal, 12)
                .frame(minHeight: 38)
                .background(Theme.contentBg, in: RoundedRectangle(cornerRadius: Theme.Radius.button))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.button)
                        .stroke(Theme.accent, lineWidth: 1.5))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.button)
                        .stroke(focused ? Theme.focusRing : .clear, lineWidth: 3))
                .onSubmit { Task { await vm.sendChat() } }

            Button {
                Task { await vm.sendChat() }
            } label: {
                if vm.isBusy {
                    ProgressView().controlSize(.small).frame(width: 44)
                } else {
                    Text("Send")
                }
            }
            .buttonStyle(.pinpointPrimary)
            .disabled(vm.isBusy)
            .keyboardShortcut(.return, modifiers: .command)
        }
    }
}

// MARK: Grouped result card

struct ResultCard: View {
    @ObservedObject var vm: ViewModel

    var body: some View {
        VStack(spacing: 0) {
            if let guess = vm.guess {
                header(guess)
                divider
                confidence(guess)
                divider
            }
            SuggestedMap(current: vm.guess == nil ? nil : vm.selectedItem?.coordinate,
                         suggestion: vm.guess?.coordinate,
                         editable: $vm.editableCoordinate,
                         framingToken: vm.mapFramingToken,
                         identity: vm.selectedID ?? "")
                .frame(height: 230)
            divider
            coordsRow
            if vm.isLoadingReferences || !vm.referencePhotos.isEmpty {
                divider
                ReferenceStrip(vm: vm)
            }
        }
        .background(Theme.contentBg)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.separatorMedium, lineWidth: 1))
        .shadow(color: .black.opacity(0.05), radius: 3, y: 1)
    }

    private var divider: some View { Rectangle().fill(Theme.separatorLight).frame(height: 1) }

    private func header(_ guess: LocationGuess) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Theme.alert).frame(width: 22, height: 22)
                Image(systemName: "exclamationmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
            }
            Text(guess.placeName)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 8)
            Text("\(Int(guess.confidence * 100))%")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
    }

    private func confidence(_ guess: LocationGuess) -> some View {
        HStack(spacing: 12) {
            Text("Confidence").font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
            ConfidenceBar(value: guess.confidence)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var coordsRow: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                if let c = vm.writeCoordinate {
                    Text(String(format: "%.5f, %.5f", c.latitude, c.longitude))
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary)
                } else {
                    Text("Tap the map to place the pin")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                }
                Text("Tap the map or drag the pin to adjust")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 8)
            Button("Copy") { vm.copyCoordinateToPasteboard() }
                .buttonStyle(.pinpointSecondary)
                .disabled(vm.writeCoordinate == nil && vm.selectedItem?.hasLocation != true)
            Button {
                vm.requestWriteLocation()
            } label: {
                if vm.phase == .writing {
                    ProgressView().controlSize(.small).frame(width: 40)
                } else {
                    Text("Set photo location")
                }
            }
            .buttonStyle(.pinpointPrimary)
            .disabled(vm.writeCoordinate == nil || vm.phase == .writing)
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
    }
}

struct ConfidenceBar: View {
    let value: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.confidenceTrack)
                Capsule().fill(Theme.accent)
                    .frame(width: max(0, min(1, value)) * geo.size.width)
            }
        }
        .frame(height: 6)
    }
}

// MARK: Reference photos

struct ReferenceStrip: View {
    @ObservedObject var vm: ViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("REFERENCE PHOTOS · via Pexels")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.3)
                .foregroundStyle(Theme.textSecondary)
            if vm.isLoadingReferences {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading…").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(vm.referencePhotos) { ReferenceThumb(photo: $0) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 13)
        .background(Theme.inspectorBg)
    }
}

/// A single Pexels reference thumbnail; tapping opens its Pexels page.
struct ReferenceThumb: View {
    let photo: PexelsPhoto
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button { openURL(photo.pageURL) } label: {
            VStack(alignment: .leading, spacing: 3) {
                AsyncImage(url: photo.thumbURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    ZStack { Theme.separatorMedium; ProgressView().controlSize(.small) }
                }
                .frame(width: 112, height: 78)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.reference))
                Text(photo.photographer)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 112, alignment: .leading).lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: Map

/// Map with the photo's saved location (blue) and an editable red "Suggested"
/// pin the user can tap-to-place or drag. When auto-drop-pin is off, the model's
/// answer shows as a non-editable indicator until the user places their own pin.
struct SuggestedMap: View {
    var current: CLLocationCoordinate2D?
    var suggestion: CLLocationCoordinate2D?
    @Binding var editable: CLLocationCoordinate2D?
    var framingToken: Int
    /// Identity of the selected photo — re-frames the map on photo change without
    /// re-framing on every drag tick.
    var identity: String = ""

    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        MapReader { proxy in
            Map(position: $position) {
                if let current {
                    Marker("Saved", systemImage: "mappin", coordinate: current).tint(.blue)
                }
                if let pin = editable {
                    Annotation("Suggested", coordinate: pin) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.title)
                            .foregroundStyle(Theme.alert)
                            .shadow(radius: 2)
                            .gesture(
                                DragGesture(coordinateSpace: .named("pinMap"))
                                    .onChanged { value in
                                        if let c = proxy.convert(value.location, from: .named("pinMap")) {
                                            editable = c
                                        }
                                    })
                    }
                } else if let suggestion {
                    // Answer shown but not yet adopted as the write pin.
                    Annotation("Suggested", coordinate: suggestion) {
                        Image(systemName: "mappin.circle")
                            .font(.title)
                            .foregroundStyle(Theme.alert.opacity(0.7))
                            .onTapGesture { editable = suggestion }
                    }
                }
            }
            .coordinateSpace(.named("pinMap"))
            .mapControls { MapCompass() }
            .gesture(
                SpatialTapGesture(coordinateSpace: .named("pinMap"))
                    .onEnded { value in
                        if let c = proxy.convert(value.location, from: .named("pinMap")) {
                            editable = c
                        }
                    })
        }
        .onAppear { position = framedPosition() }
        .onChange(of: framingKey) { position = framedPosition() }   // saved pin changed
        .onChange(of: framingToken) { position = framedPosition() } // new guess pin
        .onChange(of: identity) { position = framedPosition() }     // photo switched
    }

    private var framingKey: String { "\(current?.latitude ?? 0),\(current?.longitude ?? 0)" }

    /// Frame to fit the saved + suggested/editable pins. `.automatic` on a single
    /// marker collapses to a zero-size region and renders a blank map.
    private func framedPosition() -> MapCameraPosition {
        let coords = [current, editable, suggestion].compactMap { $0 }
        guard !coords.isEmpty else {
            return .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 30, longitude: 0),
                span: MKCoordinateSpan(latitudeDelta: 120, longitudeDelta: 120)))
        }
        if coords.count == 1 {
            return .region(MKCoordinateRegion(
                center: coords[0],
                span: MKCoordinateSpan(latitudeDelta: 0.4, longitudeDelta: 0.4)))
        }
        let lats = coords.map(\.latitude), lons = coords.map(\.longitude)
        let center = CLLocationCoordinate2D(latitude: (lats.min()! + lats.max()!) / 2,
                                            longitude: (lons.min()! + lons.max()!) / 2)
        let span = MKCoordinateSpan(
            latitudeDelta: max((lats.max()! - lats.min()!) * 1.6, 0.4),
            longitudeDelta: max((lons.max()! - lons.min()!) * 1.6, 0.4))
        return .region(MKCoordinateRegion(center: center, span: span))
    }
}
