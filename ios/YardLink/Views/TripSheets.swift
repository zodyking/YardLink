import QuickLook
import SwiftUI

// The sheets that open from a trip: where it is going, its seal, the update
// to dispatch, the site phone lines, and its photos and paperwork.

/// What one trip contributes to an update to dispatch.
struct TripUpdateFields {
    let tripId: String
    let status: String
    let isLoaded: Bool
    let containerNumber: String?
    let sealNumber: String?
    let chassisNumber: String?
    let containerType: String?
    let originName: String?
    let destinationName: String?
    let customer: String?

    init(_ active: HomePayload.Active) {
        tripId = active.trip.id
        status = active.trip.status
        isLoaded = active.trip.isLoaded ?? false
        containerNumber = active.container?.number
        sealNumber = active.trip.sealNumber
        chassisNumber = active.chassis?.number
        containerType = active.container?.containerType
        originName = active.origin?.name
        destinationName = active.destination?.name
        customer = active.trip.customer
    }

    init(_ detail: TripDetail) {
        tripId = detail.trip.id
        status = detail.trip.status
        isLoaded = detail.trip.isLoaded ?? false
        containerNumber = detail.container?.number
        sealNumber = detail.trip.sealNumber
        chassisNumber = detail.chassis?.number
        containerType = detail.container?.containerType
        originName = detail.origin?.name
        destinationName = detail.destination?.name
        customer = detail.trip.customer
    }
}

/// The wording of an update to dispatch. It is the web app's wording, so a
/// dispatcher reads the same message whichever the driver used.
enum TripUpdate {
    enum Action {
        case pickup, dropoff
    }

    /// A pickup update once the pickup is confirmed; a drop-off update after
    /// arriving. Nothing to send before that.
    static func action(for status: String) -> Action? {
        switch status {
        case "IN_TRANSIT", "DROPOFF_IN_PROGRESS": return .pickup
        case "DROPPED_OFF", "COMPLETED": return .dropoff
        default: return nil
        }
    }

    private static func clean(_ text: String?) -> String {
        (text ?? "").trimmingCharacters(in: .whitespaces)
    }

    private static func lines(_ action: Action, _ fields: TripUpdateFields, loaded: Bool) -> [String] {
        let word = loaded ? "Load" : "Empty"
        var lines = [action == .pickup ? "Picked Up \(word) ⬆️" : "Dropped \(word) ⬇️"]

        let container = Marking.formatContainer(fields.containerNumber)
        if !container.isEmpty { lines.append("CT: \(container)") }
        let seal = clean(fields.sealNumber)
        if loaded && !seal.isEmpty { lines.append("Seal: \(seal)") }
        let chassis = clean(fields.chassisNumber)
        if !chassis.isEmpty { lines.append("Chassis: \(chassis)") }

        let origin = clean(fields.originName)
        let destination = clean(fields.destinationName)
        let customer = clean(fields.customer)
        let place = action == .pickup
            ? [origin, customer, destination].first { !$0.isEmpty }
            : [destination, customer, origin].first { !$0.isEmpty }
        if let place { lines.append("@\(place)") }

        if let line = Words.line(fields.containerType) { lines.append("\(line) Container") }
        return lines
    }

    static func message(_ action: Action, _ fields: TripUpdateFields) -> String {
        lines(action, fields, loaded: fields.isLoaded).joined(separator: "\n")
    }

    /// The load leaving the customer, then the empty left behind.
    static func swapMessage(picked: TripUpdateFields, dropped: TripUpdateFields) -> String {
        (["Swap 🔁", ""] + lines(.pickup, picked, loaded: true) + [""] + lines(.dropoff, dropped, loaded: false))
            .joined(separator: "\n")
    }
}

// MARK: - Picking a location

/// A searchable list of the company's locations. Tapping one runs `onPick`;
/// the sheet closes when that succeeds and shows the reason when it does not.
struct LocationPickerSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let title: String
    var hint: String?
    var selectedId: String?
    var excludeId: String?
    let onPick: (LocationListItem, APIClient) async throws -> Void

    @State private var locations: [LocationListItem] = []
    @State private var search = ""
    @State private var loading = true
    @State private var savingId: String?
    @State private var errorMessage: String?

    private var options: [LocationListItem] {
        let pool = locations.filter { $0.id != excludeId }
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return pool }
        return pool.filter {
            $0.name.lowercased().contains(needle)
                || ($0.addressLine1 ?? "").lowercased().contains(needle)
                || ($0.city ?? "").lowercased().contains(needle)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let errorMessage { ErrorBanner(message: errorMessage) }
                    if let hint {
                        Text(hint).font(.footnote).foregroundColor(Brand.muted)
                    }
                    SearchField(prompt: "Search locations", text: $search)
                    if loading {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 120)
                    } else if options.isEmpty {
                        EmptyNote(title: "No locations match", detail: "Pick a yard, terminal or customer.")
                    } else {
                        ForEach(options) { location in
                            OptionRow(
                                symbol: Words.locationSymbol(location.type),
                                title: location.name,
                                detail: location.addressLine,
                                trailing: savingId == location.id ? "SAVING" : nil,
                                selected: selectedId == location.id
                            ) { Task { await pick(location) } }
                        }
                    }
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .screenBackground()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .lightBar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        guard let api = model.api else { return }
        do {
            let list: LocationList = try await api.get("/api/locations", query: ["limit": "200", "lite": "1"])
            locations = list.items.filter { !($0.isUncategorized ?? false) }
        } catch {
            errorMessage = model.handle(error)
        }
        loading = false
    }

    private func pick(_ location: LocationListItem) async {
        guard let api = model.api, savingId == nil else { return }
        savingId = location.id
        errorMessage = nil
        defer { savingId = nil }
        do {
            try await onPick(location, api)
            dismiss()
        } catch {
            errorMessage = model.handle(error)
        }
    }
}

// MARK: - Drop-off

/// Set or change where a live trip is going.
struct DestinationPickerView: View {
    let tripId: String
    let currentId: String?
    let originId: String?
    let onSaved: () -> Void

    private struct Payload: Encodable {
        let destinationLocationId: String
    }

    var body: some View {
        LocationPickerSheet(title: "Drop-off", selectedId: currentId, excludeId: originId) { location, api in
            let _: OkResult = try await api.post("/api/trips/\(tripId)/destination", body: Payload(destinationLocationId: location.id))
            onSaved()
        }
    }
}

// MARK: - Seal

/// Correct the seal number on a loaded live trip.
struct SealSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let tripId: String
    let onSaved: () -> Void

    @State private var seal: String
    @State private var saving = false
    @State private var errorMessage: String?
    @State private var eventId = UUID().uuidString.lowercased()

    init(tripId: String, current: String?, onSaved: @escaping () -> Void) {
        self.tripId = tripId
        self.onSaved = onSaved
        _seal = State(initialValue: current ?? "")
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                if let errorMessage { ErrorBanner(message: errorMessage) }
                FieldLabel(text: "Seal number")
                FieldBox {
                    TextField("Seal number", text: $seal)
                        .font(.system(.title3, design: .monospaced))
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                }
                Text("The correction is recorded on the trip and on the container.")
                    .font(.footnote)
                    .foregroundColor(Brand.muted)
                Button(saving ? "Saving…" : "Save Seal") { Task { await save() } }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(saving || seal.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer(minLength: 0)
            }
            .padding(16)
            .screenBackground()
            .navigationTitle("Correct Seal")
            .navigationBarTitleDisplayMode(.inline)
            .lightBar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private struct Payload: Encodable {
        let eventId: String
        let sealNumber: String
    }

    private func save() async {
        guard let api = model.api else { return }
        saving = true
        errorMessage = nil
        defer { saving = false }
        do {
            let _: OkResult = try await api.patch(
                "/api/trips/\(tripId)/seal",
                body: Payload(eventId: eventId, sealNumber: seal.trimmingCharacters(in: .whitespaces))
            )
            onSaved()
            dismiss()
        } catch {
            errorMessage = model.handle(error)
        }
    }
}

// MARK: - Contacts

/// Phone lines at the pickup and the drop-off. Tap to call.
struct ContactsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let origin: NamedPlace?
    let destination: NamedPlace?

    private func hasPhone(_ place: NamedPlace?) -> Bool {
        (place?.mainPhone?.isEmpty == false) || (place?.contactPhone?.isEmpty == false)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !hasPhone(origin) && !hasPhone(destination) {
                        EmptyNote(title: "No phone numbers", detail: "Neither location has a phone number on file. Ask dispatch.")
                    }
                    site(label: "Pickup", place: origin)
                    site(label: "Drop-off", place: destination)
                }
                .padding(16)
            }
            .screenBackground()
            .navigationTitle("Contacts")
            .navigationBarTitleDisplayMode(.inline)
            .lightBar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func site(label: String, place: NamedPlace?) -> some View {
        if hasPhone(place) {
            SectionTitle(text: "\(label) · \(place?.name ?? "")")
            Card {
                PhoneRow(label: "Main line", number: place?.mainPhone)
                PhoneRow(label: place?.contactName ?? "Contact", number: place?.contactPhone)
            }
        }
    }
}

// MARK: - Send update

/// Send the pickup or drop-off update to dispatch, with the trip's photos.
struct SendUpdateSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    /// One trip, or the load and the empty of a customer swap.
    let trip: TripUpdateFields
    var swapDropped: TripUpdateFields?

    @State private var files: [DocumentItem] = []
    @State private var selected: Set<String> = []
    @State private var sending = false
    @State private var sent = false
    @State private var errorMessage: String?
    @State private var messageId = UUID().uuidString.lowercased()
    @State private var preparingText = false
    @State private var texting = false
    @State private var textAttachments: [(data: Data, fileName: String)] = []

    private var isSwap: Bool { swapDropped != nil }
    private var action: TripUpdate.Action? { isSwap ? .pickup : TripUpdate.action(for: trip.status) }
    private var message: String {
        if let swapDropped { return TripUpdate.swapMessage(picked: trip, dropped: swapDropped) }
        guard let action else { return "" }
        return TripUpdate.message(action, trip)
    }

    /// A drop-off update is text only, as on the web.
    private var attachesFiles: Bool { isSwap || action == .pickup }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let errorMessage { ErrorBanner(message: errorMessage) }
                    if sent { Banner(kind: .success, message: "Sent to dispatch.") }

                    SectionTitle(text: "Message")
                    Card {
                        Text(message)
                            .font(.body)
                            .foregroundColor(Brand.navy)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if attachesFiles {
                        SectionTitle(text: "Photos and documents")
                        if files.isEmpty {
                            Text("Nothing is saved on this trip yet. Add photos from Documents, then send.")
                                .font(.footnote)
                                .foregroundColor(Brand.muted)
                        } else {
                            Card {
                                ForEach(files) { file in
                                    Toggle(isOn: Binding(
                                        get: { selected.contains(file.id) },
                                        set: { on in
                                            if on { selected.insert(file.id) } else { selected.remove(file.id) }
                                        }
                                    )) {
                                        Label(file.fileName, systemImage: file.isImage ? "photo" : "doc.text")
                                            .font(.subheadline)
                                            .foregroundColor(Brand.navy)
                                    }
                                    .tint(Brand.linkBlue)
                                }
                            }
                        }
                    } else {
                        Text("Drop-off updates are text only.")
                            .font(.footnote)
                            .foregroundColor(Brand.muted)
                    }

                    if MessageComposer.isAvailable {
                        Button {
                            Task { await openText() }
                        } label: {
                            Label(preparingText ? "Getting the photos…" : "Send as a Text", systemImage: "message.fill")
                                .frame(maxWidth: .infinity, minHeight: 48)
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(preparingText)
                        Text("Opens the phone's Messages app with this written out. It goes from your own number.")
                            .font(.footnote)
                            .foregroundColor(Brand.muted)
                    }

                    ShareLink(item: message) {
                        Label("Share Another Way", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                .padding(16)
            }
            .screenBackground()
            .navigationTitle("Send Update")
            .navigationBarTitleDisplayMode(.inline)
            .lightBar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                BottomBar {
                    Button(sending ? "Sending…" : "Send to Dispatch") { Task { await send() } }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(sending || sent || message.isEmpty)
                }
            }
            .sheet(isPresented: $texting) {
                MessageComposer(body: message, attachments: textAttachments)
                    .ignoresSafeArea()
            }
            .task { await loadFiles() }
        }
    }

    /// Fetch the ticked photos so the text carries them, then hand the whole
    /// thing to the phone's Messages app.
    private func openText() async {
        guard let api = model.api else { return }
        preparingText = true
        defer { preparingText = false }
        var ready: [(data: Data, fileName: String)] = []
        for file in files where selected.contains(file.id) && file.isImage {
            if let data = try? await api.data("/api/documents/\(file.id)/file") {
                ready.append((data, file.fileName))
            }
        }
        textAttachments = ready
        texting = true
    }

    private func loadFiles() async {
        guard attachesFiles, let api = model.api else { return }
        var found: [DocumentItem] = []
        for id in [trip.tripId, swapDropped?.tripId].compactMap({ $0 }) {
            if let items = try? await TripFiles.list(.trip(id), api: api) { found += items }
        }
        files = found
        selected = Set(found.map(\.id))
    }

    private struct Payload: Encodable {
        let id: String
        let body: String
        let kind: String
        let tripId: String
        let documentIds: [String]
    }

    private func send() async {
        guard let api = model.api else { return }
        sending = true
        errorMessage = nil
        defer { sending = false }
        do {
            // The id makes a retry on a weak signal count once.
            let _: OkResult = try await api.post("/api/messages/dispatch", body: Payload(
                id: messageId,
                body: message,
                kind: "TRIP_UPDATE",
                tripId: trip.tripId,
                documentIds: files.map(\.id).filter { selected.contains($0) }
            ))
            sent = true
            try? await Task.sleep(nanoseconds: 900_000_000)
            dismiss()
        } catch {
            errorMessage = model.handle(error)
        }
    }
}

// MARK: - Documents

/// Photos and paperwork on a trip or a container: look, add, remove.
struct DocumentsSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let scope: FileScope
    let equipmentNumber: String?

    @State private var files: [DocumentItem] = []
    @State private var loading = true
    @State private var working = false
    @State private var errorMessage: String?
    @State private var showingCamera = false
    @State private var preview: URL?
    @State private var removing: DocumentItem?

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 10)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let errorMessage { ErrorBanner(message: errorMessage) }

                    Button {
                        showingCamera = true
                    } label: {
                        Label(working ? "Saving…" : "Take a Photo", systemImage: "camera.fill")
                    }
                    .buttonStyle(DarkButtonStyle())
                    .disabled(working)

                    if loading {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 120)
                    } else if files.isEmpty {
                        EmptyNote(title: "Nothing saved yet", detail: "Photos of the container and its paperwork are kept here and can go to dispatch with your update.")
                    } else {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(files) { file in
                                tile(file)
                            }
                        }
                    }
                }
                .padding(16)
            }
            .screenBackground()
            .navigationTitle("Documents")
            .navigationBarTitleDisplayMode(.inline)
            .lightBar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .fullScreenCover(isPresented: $showingCamera) {
                CameraCapture { image in
                    Task { await add(image) }
                }
                .ignoresSafeArea()
            }
            .quickLookPreview($preview)
            .confirmationDialog(
                "Remove this file?",
                isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                titleVisibility: .visible,
                presenting: removing
            ) { file in
                Button("Remove", role: .destructive) { Task { await remove(file) } }
                Button("Keep", role: .cancel) {}
            } message: { file in
                Text(file.fileName)
            }
            .task { await load() }
        }
    }

    private func tile(_ file: DocumentItem) -> some View {
        Button {
            Task { await open(file) }
        } label: {
            VStack(spacing: 6) {
                Group {
                    if file.isImage {
                        ServerImage(documentId: file.id)
                    } else {
                        ZStack {
                            Brand.skyWash
                            Image(systemName: "doc.text.fill").font(.title).foregroundColor(Brand.linkBlue)
                        }
                    }
                }
                .frame(height: 104)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text(file.fileName)
                    .font(.caption)
                    .foregroundColor(Brand.ink)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                removing = file
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
        .accessibilityLabel(file.fileName)
        .accessibilityHint("Opens the file. Touch and hold to remove it.")
    }

    private func load() async {
        guard let api = model.api else { return }
        do {
            files = try await TripFiles.list(scope, api: api)
            errorMessage = nil
        } catch {
            errorMessage = model.handle(error)
        }
        loading = false
    }

    private func add(_ image: UIImage) async {
        working = true
        defer { working = false }
        let stamp = Int(Date().timeIntervalSince1970)
        do {
            try await TripFiles.upload(image, named: "\(equipmentNumber ?? "photo")-\(stamp).jpg", to: scope, api: model.api)
            await load()
        } catch {
            errorMessage = model.handle(error)
        }
    }

    /// Fetch the file with the signed-in session and show it full screen.
    private func open(_ file: DocumentItem) async {
        guard let api = model.api else { return }
        do {
            let data = try await api.data("/api/documents/\(file.id)/file")
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(file.fileName)
            try data.write(to: url, options: .atomic)
            preview = url
        } catch {
            errorMessage = model.handle(error)
        }
    }

    private func remove(_ file: DocumentItem) async {
        guard let api = model.api else { return }
        do {
            let _: OkResult = try await api.delete("/api/documents/\(file.id)")
            await load()
        } catch {
            errorMessage = model.handle(error)
        }
    }
}
