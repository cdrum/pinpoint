import SwiftUI
import Photos
import CoreLocation
import MapKit

@MainActor
final class ViewModel: ObservableObject {
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
    @Published var isChatting = false

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
        referencePhotos = []; editableCoordinate = nil
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
        isChatting = true
        defer { isChatting = false }

        // Attach the image on the first user turn only.
        var imageData: Data?
        if isFirstTurn {
            guard let jpeg = await library.jpegForAnalysis(asset) else {
                message = "Couldn't load full-size image."
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
        do {
            let response = try await provider.chat(system: system, messages: conversation,
                                                   model: settings.selectedModelID,
                                                   apiKey: settings.activeAPIKey)
            let extraction = LocationParsing.extract(from: response.rawText)
            let display = extraction.display.isEmpty ? response.rawText : extraction.display

            transcript.append(ChatTurn(role: .assistant, text: display, model: settings.selectedModelID))
            conversation.append(ChatMessage(role: .assistant, text: response.rawText))
            if let u = response.usage { usage.add(u) }

            if let place = extraction.placeName {
                let changed = (guess?.placeName != place)
                guess = LocationGuess(placeName: place, confidence: extraction.confidence,
                                      reasoning: display, coordinate: guess?.coordinate)
                if changed {
                    // A new place was agreed on — re-geocode and re-fetch references.
                    if let coord = await Geocoding.resolve(place) {
                        guess?.coordinate = coord
                        editableCoordinate = coord
                        mapFramingToken += 1   // re-frame the map to show the new pin
                    }
                    await loadReferences(for: place)
                }
            }

            logTurn(asset: asset, userText: userText, place: extraction.placeName,
                    confidence: extraction.placeName == nil ? nil : extraction.confidence,
                    usage: response.usage, success: true, error: nil)
        } catch {
            // Roll back the optimistic user turn so a retry is clean.
            transcript.removeLast()
            conversation.removeLast()
            chatInput = userText
            if isFirstTurn { currentJPEG = nil }
            message = error.localizedDescription
            logTurn(asset: asset, userText: userText, place: nil, confidence: nil,
                    usage: nil, success: false, error: error.localizedDescription)
        }
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

    func writeLocation() async {
        guard let id = selectedID, let coordinate = editableCoordinate else { return }
        await applyLocation(coordinate, to: id, successMessage: "Location written. ✓")
    }

    /// Copy the selected photo's location (the editable pin, or its saved one)
    /// so it can be stamped onto other photos.
    func copyLocation() {
        copiedCoordinate = editableCoordinate ?? selectedItem?.coordinate
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
            if filter == .has {
                dropFromList(id)   // no longer matches "Has location"
            }
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

struct ContentView: View {
    @StateObject private var vm = ViewModel()
    @State private var showingSettings = false
    @State private var showingHistory = false

    var body: some View {
        NavigationSplitView {
            albumSidebar
        } content: {
            photoColumn
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { showingHistory = true } label: { Image(systemName: "clock.arrow.circlepath") }
                Button { showingSettings = true } label: { Image(systemName: "gearshape") }
            }
        }
        .sheet(isPresented: $showingSettings) { SettingsView() }
        .sheet(isPresented: $showingHistory) { HistoryView() }
        .task { await vm.start() }
        .onChange(of: vm.selectedCollectionID) { Task { await vm.reloadPhotos() } }
        .onChange(of: vm.filter) { Task { await vm.reloadPhotos() } }
        .onChange(of: vm.selectedID) { vm.photoSelectionChanged() }
    }

    // MARK: - Column 1: albums / folders

    private var albumSidebar: some View {
        Group {
            if vm.status != .authorized && vm.status != .limited {
                ContentUnavailableView("Photo access needed", systemImage: "lock",
                                       description: Text("Grant access in System Settings › Privacy › Photos, then reopen."))
            } else {
                List(selection: $vm.selectedCollectionID) {
                    OutlineGroup(vm.collections, children: \.children) { node in
                        Label(node.title, systemImage: node.systemImage).tag(node.id)
                    }
                }
            }
        }
        .frame(minWidth: 220)
        .navigationTitle("Albums")
    }

    // MARK: - Column 2: photos + filter

    private var photoColumn: some View {
        VStack(spacing: 0) {
            Picker("Filter", selection: $vm.filter) {
                ForEach(LocationFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().padding(8)
            Divider()
            photoList
        }
        .frame(minWidth: 260)
        .navigationTitle("Photos")
    }

    private var photoList: some View {
        Group {
            if vm.selectedCollectionID == nil {
                ContentUnavailableView("Pick an album", systemImage: "rectangle.stack")
            } else if vm.isLoading {
                ProgressView("Scanning…")
            } else if vm.items.isEmpty {
                ContentUnavailableView(emptyTitle, systemImage: "photo.on.rectangle.angled")
            } else {
                List(vm.items, selection: $vm.selectedID) { item in
                    HStack {
                        thumbnailView(item.thumbnail)
                        VStack(alignment: .leading) {
                            Text(item.creationDate.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "Unknown date")
                                .font(.callout)
                            Label(item.hasLocation ? "Has location" : "No location",
                                  systemImage: item.hasLocation ? "mappin.circle.fill" : "mappin.slash")
                                .font(.caption)
                                .foregroundStyle(item.hasLocation ? Color.blue : .secondary)
                        }
                        Spacer()
                        rowActions(for: item)
                    }
                    .tag(item.id)
                }
            }
        }
    }

    /// Per-row quick actions: paste the copied location, and remove location.
    @ViewBuilder
    private func rowActions(for item: PhotoItem) -> some View {
        HStack(spacing: 4) {
            if vm.copiedCoordinate != nil {
                Button { Task { await vm.pasteLocation(to: item.id) } } label: {
                    Image(systemName: "mappin.and.ellipse")
                }
                .buttonStyle(.borderless)
                .help("Paste copied location onto this photo")
            }
            if item.hasLocation {
                Button { Task { await vm.removeLocation(id: item.id) } } label: {
                    Image(systemName: "mappin.slash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .help("Remove this photo's location")
            }
        }
    }

    private var emptyTitle: String {
        switch vm.filter {
        case .missing: return "No photos missing location"
        case .has: return "No photos with location"
        case .all: return "No photos"
        }
    }

    // MARK: - Column 3: detail (photo, chat, map)

    @ViewBuilder
    private var detail: some View {
        if let item = vm.selectedItem {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let thumb = item.thumbnail {
                        Image(decorative: thumb, scale: 1)
                            .resizable().scaledToFit()
                            .frame(maxHeight: 240)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    conversationSection
                    chatInputRow

                    if let guess = vm.guess { locationCard(guess) }

                    EditableLocationMapView(current: item.coordinate,
                                            editable: $vm.editableCoordinate,
                                            framingToken: vm.mapFramingToken)
                    writeBar
                    locationActionsBar
                    referenceSection

                    if let message = vm.message {
                        Text(message).foregroundStyle(.secondary)
                    }
                }
                .padding(24)
            }
        } else {
            ContentUnavailableView("Select a photo", systemImage: "photo.on.rectangle")
        }
    }

    // MARK: Conversation

    @ViewBuilder
    private var conversationSection: some View {
        if !vm.transcript.isEmpty {
            VStack(spacing: 8) {
                ForEach(vm.transcript) { turn in
                    ChatBubble(turn: turn,
                               onSetDescription: turn.role == .assistant
                                   ? { Task { await vm.setDescription(turn.text) } }
                                   : nil)
                }
            }
        }
    }

    private var chatInputRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            if vm.transcript.isEmpty {
                Text("Ask where this was taken — add any hints (place, year, landmarks).")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack(alignment: .bottom) {
                TextField(vm.transcript.isEmpty ? "e.g. Madrid 1998, I think it's by Puerta del Sol"
                                                : "Reply… (confirm, correct, or ask a question)",
                          text: $vm.chatInput, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await vm.sendChat() } }
                Button(action: { Task { await vm.sendChat() } }) {
                    if vm.isChatting {
                        ProgressView().controlSize(.small)
                    } else {
                        Label(vm.transcript.isEmpty ? "Request location from LLM" : "Send",
                              systemImage: "paperplane.fill")
                    }
                }
                .disabled(vm.isChatting)
            }
            if vm.usage.turns > 0 {
                Text(usageLine(vm.usage)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Extracted location

    private func locationCard(_ guess: LocationGuess) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "mappin.circle.fill").foregroundStyle(.red)
                Text(guess.placeName).font(.headline)
            }
            HStack {
                Text("Confidence").font(.caption)
                ProgressView(value: guess.confidence)
                Text("\(Int(guess.confidence * 100))%").font(.caption).monospacedDigit()
            }
            if guess.coordinate == nil {
                Label("Couldn't geocode this place — drop a pin on the map below.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var writeBar: some View {
        HStack {
            if let coord = vm.editableCoordinate {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: "%.5f, %.5f", coord.latitude, coord.longitude))
                        .font(.callout.monospaced())
                    Text("Tap the map or drag the red pin to adjust.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Tap the map to drop a pin.").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: { Task { await vm.writeLocation() } }) {
                Label("Set photo location", systemImage: "mappin.and.ellipse")
            }
            .buttonStyle(.borderedProminent)
            .disabled(vm.editableCoordinate == nil)
        }
    }

    /// Copy / paste / remove actions for the selected photo's location.
    @ViewBuilder
    private var locationActionsBar: some View {
        HStack {
            Button { vm.copyLocation() } label: { Label("Copy location", systemImage: "doc.on.doc") }
                .disabled(vm.editableCoordinate == nil && vm.selectedItem?.hasLocation != true)

            if vm.copiedCoordinate != nil, let id = vm.selectedID {
                Button { Task { await vm.pasteLocation(to: id) } } label: {
                    Label("Paste location", systemImage: "doc.on.clipboard")
                }
            }
            if vm.selectedItem?.hasLocation == true, let id = vm.selectedID {
                Button(role: .destructive) { Task { await vm.removeLocation(id: id) } } label: {
                    Label("Remove location", systemImage: "mappin.slash")
                }
            }
            Spacer()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    @ViewBuilder
    private var referenceSection: some View {
        if vm.isLoadingReferences {
            HStack { ProgressView().controlSize(.small); Text("Loading reference photos…").font(.caption).foregroundStyle(.secondary) }
        } else if !vm.referencePhotos.isEmpty, let place = vm.guess?.placeName {
            VStack(alignment: .leading, spacing: 6) {
                Text("Reference photos of \(place) · via Pexels")
                    .font(.callout).foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(vm.referencePhotos) { ReferenceThumb(photo: $0) }
                    }
                }
            }
        } else if vm.guess != nil && AppSettings.shared.pexelsAPIKey.isEmpty {
            Text("Add a Pexels API key in Settings to compare reference photos of the guessed place.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func usageLine(_ usage: ConversationUsage) -> String {
        let turnLabel = usage.turns == 1 ? "1 turn" : "\(usage.turns) turns"
        var parts = ["\(turnLabel)", "\(usage.promptTokens) in", "\(usage.completionTokens) out tokens"]
        if usage.hasCost { parts.append(String(format: "$%.4f total", usage.costUSD)) }
        return parts.joined(separator: " · ")
    }

    private func thumbnailView(_ cg: CGImage?) -> some View {
        Group {
            if let cg { Image(decorative: cg, scale: 1).resizable() }
            else { Color.secondary.opacity(0.2) }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

/// A single chat bubble: user aligned right, assistant left. Assistant bubbles
/// carry a "Set as description" action that writes the text to the photo caption.
struct ChatBubble: View {
    let turn: ChatTurn
    var onSetDescription: (() -> Void)?

    private var isUser: Bool { turn.role == .user }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 40) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                Text(turn.text)
                    .textSelection(.enabled)
                    .padding(10)
                    .background(isUser ? Color.accentColor.opacity(0.20) : Color.secondary.opacity(0.15),
                                in: RoundedRectangle(cornerRadius: 10))
                if !isUser {
                    HStack(spacing: 10) {
                        if let onSetDescription {
                            Button(action: onSetDescription) {
                                Label("Set as description", systemImage: "text.badge.plus")
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                        }
                        if let model = turn.model {
                            Label(model, systemImage: "cpu")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                }
            }
            if !isUser { Spacer(minLength: 40) }
        }
    }
}

/// Map with the photo's saved location (blue) and an editable pin (red) the
/// user can tap-to-place or drag to fine-tune. Writes back through `editable`.
struct EditableLocationMapView: View {
    var current: CLLocationCoordinate2D?
    @Binding var editable: CLLocationCoordinate2D?
    var framingToken: Int

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
                            .font(.title).foregroundStyle(.red).shadow(radius: 2)
                            .gesture(
                                DragGesture(coordinateSpace: .named("pinMap"))
                                    .onChanged { value in
                                        if let c = proxy.convert(value.location, from: .named("pinMap")) {
                                            editable = c
                                        }
                                    }
                            )
                    }
                }
            }
            .coordinateSpace(.named("pinMap"))
            .gesture(
                SpatialTapGesture(coordinateSpace: .named("pinMap"))
                    .onEnded { value in
                        if let c = proxy.convert(value.location, from: .named("pinMap")) {
                            editable = c
                        }
                    }
            )
        }
        .frame(height: 240)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onAppear { position = framedPosition() }
        .onChange(of: framingKey) { position = framedPosition() }   // photo switched
        .onChange(of: framingToken) { position = framedPosition() } // new guess pin
    }

    /// Re-frame only when the *saved* pin changes — not on every drag tick.
    private var framingKey: String { "\(current?.latitude ?? 0),\(current?.longitude ?? 0)" }

    /// Frame to fit both pins (saved + suggested). `.automatic` on a single
    /// marker collapses to a zero-size region and renders a blank green map.
    private func framedPosition() -> MapCameraPosition {
        let coords = [current, editable].compactMap { $0 }
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

/// A single Pexels reference thumbnail; tapping opens its Pexels page.
struct ReferenceThumb: View {
    let photo: PexelsPhoto
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button { openURL(photo.pageURL) } label: {
            VStack(alignment: .leading, spacing: 2) {
                AsyncImage(url: photo.thumbURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    ZStack { Color.secondary.opacity(0.15); ProgressView().controlSize(.small) }
                }
                .frame(width: 150, height: 110)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                Text(photo.photographer)
                    .font(.caption2).foregroundStyle(.secondary)
                    .frame(width: 150, alignment: .leading).lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }
}
