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

// MARK: - Trip notes

/// Correct a trip's notes after the fact. Works on a trip of any status —
/// old, finished trips and ones recorded to fill a missing-trip gap are
/// editable here too, not just live ones.
struct EditTripNotesSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let tripId: String
    let onSaved: () -> Void

    @State private var notes: String
    @State private var saving = false
    @State private var errorMessage: String?

    init(tripId: String, current: String?, onSaved: @escaping () -> Void) {
        self.tripId = tripId
        self.onSaved = onSaved
        _notes = State(initialValue: current ?? "")
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                if let errorMessage { ErrorBanner(message: errorMessage) }
                FieldLabel(text: "Notes")
                FieldBox {
                    TextField("Anything dispatch should know", text: $notes, axis: .vertical)
                        .lineLimit(4...8)
                }
                Text("This is saved on the trip, whatever its status.")
                    .font(.footnote)
                    .foregroundColor(Brand.muted)
                Button(saving ? "Saving…" : "Save Notes") { Task { await save() } }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(saving)
                Spacer(minLength: 0)
            }
            .padding(16)
            .screenBackground()
            .navigationTitle("Edit Notes")
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
        let notes: String?
    }

    private func save() async {
        guard let api = model.api else { return }
        saving = true
        errorMessage = nil
        defer { saving = false }
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let _: OkResult = try await api.patch(
                "/api/trips/\(tripId)",
                body: Payload(notes: trimmed.isEmpty ? nil : trimmed)
            )
            onSaved()
            dismiss()
        } catch {
            errorMessage = model.handle(error)
        }
    }
}

/// Correct a trip's customer after the fact. Works on a trip of any status
/// — old, finished trips and ones recorded to fill a missing-trip gap are
/// editable here too, not just live ones. A time card stop for this trip
/// carries the same correction back if it's edited there instead.
struct EditCustomerSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let tripId: String
    let onSaved: () -> Void

    @State private var customer: String
    @State private var saving = false
    @State private var errorMessage: String?

    init(tripId: String, current: String?, onSaved: @escaping () -> Void) {
        self.tripId = tripId
        self.onSaved = onSaved
        _customer = State(initialValue: current ?? "")
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                if let errorMessage { ErrorBanner(message: errorMessage) }
                FieldLabel(text: "Customer")
                FieldBox {
                    TextField("Customer", text: $customer)
                }
                Text("This is saved on the trip, whatever its status, and on its time card stops too.")
                    .font(.footnote)
                    .foregroundColor(Brand.muted)
                Button(saving ? "Saving…" : "Save Customer") { Task { await save() } }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(saving)
                Spacer(minLength: 0)
            }
            .padding(16)
            .screenBackground()
            .navigationTitle("Edit Customer")
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
        let customer: String?
    }

    private func save() async {
        guard let api = model.api else { return }
        saving = true
        errorMessage = nil
        defer { saving = false }
        let trimmed = customer.trimmingCharacters(in: .whitespaces)
        do {
            let _: OkResult = try await api.patch(
                "/api/trips/\(tripId)",
                body: Payload(customer: trimmed.isEmpty ? nil : trimmed)
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
    let containerNumber: String?
    let chassisNumber: String?

    @State private var files: [DocumentItem] = []
    @State private var loading = true
    @State private var working = false
    @State private var workingKind: DocumentKind?
    @State private var errorMessage: String?
    @State private var choosingKind = false
    @State private var capturing: DocumentKind?
    @State private var viewing: DocumentItem?
    @State private var preview: URL?
    @State private var removing: DocumentItem?

    /// A paper form takes an extra moment on the server to flatten and
    /// clean up, so the button says so rather than just sitting on "Saving…"
    /// through what would otherwise look like a stall.
    private var savingLabel: String {
        guard working else { return "Add Document" }
        return workingKind?.isPaperDocument == true ? "Cleaning Up…" : "Saving…"
    }

    /// Equipment photos first, then paperwork, newest first inside each kind.
    private var sorted: [DocumentItem] {
        files.sorted { left, right in
            let leftRank = DocumentKind(rawValue: left.category ?? "")?.rank ?? 3
            let rightRank = DocumentKind(rawValue: right.category ?? "")?.rank ?? 3
            if leftRank != rightRank { return leftRank < rightRank }
            return (left.createdAt ?? .distantPast) > (right.createdAt ?? .distantPast)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let errorMessage { ErrorBanner(message: errorMessage) }

                    Button {
                        choosingKind = true
                    } label: {
                        Label(savingLabel, systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(DarkButtonStyle())
                    .disabled(working)

                    if loading {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 120)
                    } else if files.isEmpty {
                        EmptyNote(
                            title: "Nothing saved yet",
                            detail: "Photos of the equipment and its paperwork are kept here for the whole service cycle, and can go to dispatch with your update."
                        )
                    } else {
                        ForEach(sorted) { file in
                            row(file)
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
            .confirmPrompt(
                "What are you adding?",
                isPresented: $choosingKind,
                actions: DocumentKind.allCases.map { kind in
                    .secondary(kind.label) { capturing = kind }
                }
            )
            .fullScreenCover(item: $capturing) { kind in
                CameraCapture { image in
                    Task { await add(image, kind: kind) }
                }
                .ignoresSafeArea()
            }
            .fullScreenCover(item: $viewing) { file in
                DocumentViewer(file: file)
                    .environmentObject(model)
            }
            .quickLookPreview($preview)
            .confirmPrompt(
                "Remove this file?",
                message: removing?.title,
                isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                cancelLabel: "Keep",
                actions: [.destructive("Remove") {
                    if let file = removing { Task { await remove(file) } }
                }]
            )
            .task { await load() }
        }
    }

    private func row(_ file: DocumentItem) -> some View {
        Button {
            if file.isImage { viewing = file } else { Task { await openOutside(file) } }
        } label: {
            Card {
                HStack(spacing: 12) {
                    Group {
                        if file.isImage {
                            ServerImage(documentId: file.id)
                        } else {
                            ZStack {
                                Brand.skyWash
                                Image(systemName: "doc.text.fill").foregroundColor(Brand.linkBlue)
                            }
                        }
                    }
                    .frame(width: 54, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(file.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(Brand.ink)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text(DocumentKind.label(forCategory: file.category))
                            .font(.caption)
                            .foregroundColor(Brand.linkBlue)
                        if let taken = file.createdAt {
                            Text(taken.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
                }
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
        .accessibilityLabel(file.title)
        .accessibilityHint("Opens the file full screen. Touch and hold to remove it.")
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

    private func add(_ image: UIImage, kind: DocumentKind) async {
        working = true
        workingKind = kind
        defer { working = false; workingKind = nil }
        let name = uniqueDocumentName(
            kind.name(forContainer: containerNumber, chassis: chassisNumber),
            extension: "jpg",
            taken: files.map(\.fileName)
        )
        do {
            try await TripFiles.upload(image, named: name, kind: kind, to: scope, api: model.api)
            await load()
        } catch {
            errorMessage = model.handle(error)
        }
    }

    /// A file the phone cannot show itself — a PDF, say — opens in the viewer iOS brings.
    private func openOutside(_ file: DocumentItem) async {
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

/// One picture, full screen, pinch to zoom, with the system share sheet for
/// sending it on.
struct DocumentViewer: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let file: DocumentItem

    @State private var image: UIImage?
    @State private var zoom: CGFloat = 1
    @State private var committed: CGFloat = 1
    @State private var failed = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(zoom)
                        .gesture(
                            MagnificationGesture()
                                .onChanged { value in zoom = min(6, max(1, committed * value)) }
                                .onEnded { _ in committed = zoom }
                        )
                        .onTapGesture(count: 2) {
                            zoom = zoom > 1 ? 1 : 2.5
                            committed = zoom
                        }
                } else if failed {
                    Text("This file could not be loaded.").foregroundColor(.white)
                } else {
                    ProgressView().tint(.white)
                }
            }
            .navigationTitle(file.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    if let image {
                        ShareLink(item: Image(uiImage: image), preview: SharePreview(file.title, image: Image(uiImage: image))) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
            }
        }
        .task {
            guard image == nil, let api = model.api else { return }
            if let data = try? await api.data("/api/documents/\(file.id)/file"), let loaded = UIImage(data: data) {
                image = loaded
            } else {
                failed = true
            }
        }
    }
}

/// The equipment on the driver's active trip right now. Each entry opens
/// that equipment's files. Once a trip is dropped off its files are still
/// there — just reachable from Trips or the equipment's page in Inventory
/// instead of this list, which only shows what's actively in motion.
struct DriverDocumentsSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var groups: [DocumentGroup] = []
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var opened: DocumentGroup?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let errorMessage { ErrorBanner(message: errorMessage) }

                    if loading {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 120)
                    } else if groups.isEmpty {
                        EmptyNote(title: "No active trip", detail: "Photos and paperwork appear here while you're on a trip. Once it's dropped off, find its files from Trips or the equipment's page in Inventory.")
                    } else {
                        ForEach(groups) { group in
                            row(group)
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
            .sheet(item: $opened, onDismiss: { Task { await load() } }) { group in
                DocumentsSheet(scope: .trip(group.tripId), containerNumber: group.containerNumber, chassisNumber: group.chassisNumber)
                    .environmentObject(model)
                    .sheetChrome()
            }
            .task { await load() }
        }
    }

    private func row(_ group: DocumentGroup) -> some View {
        Button {
            opened = group
        } label: {
            Card {
                HStack(spacing: 12) {
                    Group {
                        if let previewDocumentId = group.previewDocumentId {
                            ServerImage(documentId: previewDocumentId)
                        } else {
                            ZStack {
                                Brand.skyWash
                                Image(systemName: "shippingbox.fill").foregroundColor(Brand.linkBlue)
                            }
                        }
                    }
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.title.isEmpty ? "Trip" : group.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(Brand.ink)
                        Text(group.count == 0 ? "No files yet" : group.count == 1 ? "1 file" : "\(group.count) files")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the files for this equipment.")
    }

    private func load() async {
        guard let api = model.api else { return }
        do {
            let list: DocumentGroupList = try await api.get("/api/documents/recent")
            groups = list.groups
            errorMessage = nil
        } catch {
            errorMessage = model.handle(error)
        }
        loading = false
    }
}
