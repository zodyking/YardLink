import SwiftUI

/// The driver's trips, newest day first.
struct TripsView: View {
    @EnvironmentObject private var model: AppModel

    @State private var trips: [TripListItem] = []
    @State private var gapAnswers: [String: String] = [:]
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var showingCalendar = false
    @State private var pickedDay: Date?
    @State private var openedTrip: OpenedTrip?
    @State private var recordingTrip: ManualTripContext?

    /// Gaps by the later trip, which is the row they are shown above.
    private var gapsByNextTrip: [String: TripGap] {
        Dictionary(TripGap.find(in: trips).map { ($0.nextTripId, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private var days: [(day: Date, trips: [TripListItem])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: trips) { calendar.startOfDay(for: $0.day) }
        return grouped.keys.sorted(by: >).map { key in
            (key, (grouped[key] ?? []).sorted { $0.day > $1.day })
        }
    }

    /// In calendar view, one chosen day; otherwise every day.
    private var shownDays: [(day: Date, trips: [TripListItem])] {
        guard showingCalendar, let pickedDay else { return showingCalendar ? [] : days }
        let calendar = Calendar.current
        return days.filter { calendar.isDate($0.day, inSameDayAs: pickedDay) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    PageHeader("Trips") {
                        Button {
                            recordingTrip = ManualTripContext(gap: nil)
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(IconButtonStyle())
                        .accessibilityLabel("Record a trip")

                        Button {
                            showingCalendar.toggle()
                            if !showingCalendar { pickedDay = nil }
                        } label: {
                            Image(systemName: showingCalendar ? "list.bullet" : "calendar")
                        }
                        .buttonStyle(IconButtonStyle())
                        .accessibilityLabel(showingCalendar ? "Show the list" : "Show a calendar")
                    }

                    if showingCalendar {
                        TripCalendar(days: Set(days.map(\.day)), selected: $pickedDay)
                    }

                    if let errorMessage { ErrorBanner(message: errorMessage) }

                    NavigationLink {
                        TimeCardsView()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "clock.badge.checkmark.fill")
                                .font(.title3)
                                .foregroundColor(Brand.linkBlue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Time Cards").font(.body.weight(.semibold)).foregroundColor(Brand.navy)
                                Text("Your stops for each day, ready to send").font(.footnote).foregroundColor(Brand.muted)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundColor(Brand.muted.opacity(0.6))
                        }
                        .padding(14)
                        .cardSurface()
                    }
                    .buttonStyle(.plain)

                    if !loading && trips.isEmpty && errorMessage == nil {
                        EmptyNote(title: "No trips yet", detail: "Trips appear here once you confirm a pickup.")
                    }

                    if showingCalendar && pickedDay == nil {
                        Text("Pick a day with a dot to see its trips.")
                            .font(.footnote)
                            .foregroundColor(Brand.muted)
                    } else if showingCalendar && shownDays.isEmpty {
                        EmptyNote(title: "No trips this day", detail: "Nothing was picked up or dropped off on this date.")
                    }

                    let gaps = gapsByNextTrip
                    ForEach(shownDays, id: \.day) { group in
                        SectionTitle(text: Format.day(group.day))
                        ForEach(group.trips) { trip in
                            if let gap = gaps[trip.id] {
                                GapCard(
                                    gap: gap,
                                    answer: gapAnswers[gap.id],
                                    onBobtail: { Task { await confirmBobtail(gap) } },
                                    onRecordMissing: { recordingTrip = ManualTripContext(gap: gap) }
                                )
                            }
                            NavigationLink(value: trip) {
                                TripRow(trip: trip)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(16)
            }
            .screenBackground()
            .overlay { if loading && trips.isEmpty { ProgressView() } }
            .brandScreen()
            .navigationDestination(for: TripListItem.self) { trip in
                TripDetailView(tripId: trip.id, onChanged: { Task { await load() } })
            }
            .sheet(item: $openedTrip) { opened in
                NavigationStack {
                    TripDetailView(tripId: opened.id, onChanged: { Task { await load() } })
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { openedTrip = nil }
                            }
                        }
                }
            }
            .sheet(item: $recordingTrip) { context in
                ManualTripEntrySheet(gap: context.gap) { tripId in
                    recordingTrip = nil
                    openedTrip = OpenedTrip(id: tripId)
                    Task { await load() }
                }
            }
            .refreshable { await load() }
            .task { await load() }
        }
    }

    private func load() async {
        guard let api = model.api else { return }
        do {
            let list: TripList = try await api.get("/api/trips", query: ["limit": "200"])
            trips = list.items
            gapAnswers = Dictionary(
                (list.gapResolutions ?? []).map { ("\($0.priorTripId):\($0.nextTripId)", $0.resolution) },
                uniquingKeysWith: { _, last in last }
            )
            errorMessage = nil
        } catch {
            errorMessage = model.handle(error)
        }
        loading = false
    }

    private struct GapPayload: Encodable {
        let priorTripId: String
        let nextTripId: String
        let resolution = "BOBTAIL"
    }

    /// A trip just opened from a gap resolution, so it can be shown right
    /// away for editing — identified separately from the main trip list's
    /// own navigation so it works whether or not the trip is in `trips` yet.
    private struct OpenedTrip: Identifiable { let id: String }

    /// What to open the manual-trip sheet with: a blank form from the "+"
    /// button, or one pre-filled to fill a specific gap.
    private struct ManualTripContext: Identifiable {
        let id = UUID()
        let gap: TripGap?
    }

    private func confirmBobtail(_ gap: TripGap) async {
        guard let api = model.api else { return }
        do {
            let _: GapResolutionResult = try await api.post("/api/trips/gaps", body: GapPayload(
                priorTripId: gap.priorTripId,
                nextTripId: gap.nextTripId
            ))
            await load()
        } catch {
            errorMessage = model.handle(error)
        }
    }
}

/// Asks about a break between two trips, or shows the bobtail that explains it.
private struct GapCard: View {
    let gap: TripGap
    let answer: String?
    let onBobtail: () -> Void
    let onRecordMissing: () -> Void

    private var isBobtail: Bool { answer == "BOBTAIL" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(isBobtail ? "Bobtail" : "Missing trip", systemImage: isBobtail ? "box.truck" : "questionmark.circle.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundColor(isBobtail ? Brand.ink : Brand.warn)
                Spacer()
                if isBobtail {
                    Menu {
                        Button("This was a missing trip") { onRecordMissing() }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(minWidth: 44, minHeight: 32)
                    }
                    .accessibilityLabel("Bobtail actions")
                }
            }
            HStack(spacing: 8) {
                Text(gap.fromName).lineLimit(1)
                Image(systemName: "arrow.right").font(.caption.weight(.bold))
                Text(gap.toName).lineLimit(1)
            }
            .font(.subheadline)
            .foregroundColor(Brand.ink)
            if !isBobtail {
                Text("The trip before this ended somewhere else. Record the trip that is missing, or confirm you drove there without a chassis.")
                    .font(.footnote)
                    .foregroundColor(Brand.muted)
                HStack(spacing: 10) {
                    Button("Record Missing Trip") { onRecordMissing() }
                        .buttonStyle(DarkButtonStyle())
                    Button("It Was a Bobtail Move") { onBobtail() }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((isBobtail ? Brand.mist : Brand.warn.opacity(0.08)))
        .clipShape(RoundedRectangle(cornerRadius: Brand.radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Brand.radius, style: .continuous)
                .stroke(isBobtail ? Brand.line : Brand.warn.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        )
    }
}

private struct TripRow: View {
    let trip: TripListItem

    private var title: String {
        if let number = trip.containerNumber, !number.isEmpty { return Marking.formatContainer(number) }
        return trip.title
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                EquipmentNumber(
                    text: title,
                    font: .system(.headline, design: .monospaced),
                    label: trip.containerNumber?.isEmpty == false ? "Container" : nil,
                    copyOnTap: false,
                    kind: trip.containerNumber?.isEmpty == false ? .container : .plain
                )
                Spacer()
                StatusPill(text: Words.tripStatus(trip.status), color: tripStatusColor(trip.status))
            }
            HStack(spacing: 8) {
                Text(trip.originName ?? "—").lineLimit(1)
                Image(systemName: "arrow.right").font(.caption.weight(.bold)).foregroundColor(Brand.linkBlue)
                Text(trip.destinationName ?? "No drop-off set").lineLimit(1)
            }
            .font(.subheadline)
            .foregroundColor(Brand.ink)
            HStack(spacing: 8) {
                if !trip.isBareChassis {
                    Text((trip.isLoaded ?? false) ? "Loaded" : "Empty")
                }
                if let line = Words.line(trip.containerType) { Text(line) }
                if let chassis = trip.chassisNumber, !chassis.isEmpty, !trip.isBareChassis { Text("On \(chassis)") }
                if trip.swapPairTripId != nil { Text("Swap") }
            }
            .font(.caption.weight(.semibold))
            .foregroundColor(Brand.muted)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .accessibilityElement(children: .combine)
    }
}

/// One trip: equipment, route, history, and what can be done with it now.
struct TripDetailView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let tripId: String
    var onChanged: () -> Void = {}

    @State private var detail: TripDetail?
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var sheet: TripSheet?
    @State private var resuming = false
    @State private var confirmingCancel = false
    @State private var confirmingDelete = false
    @State private var confirmingUnswap = false
    @State private var working = false

    private enum TripSheet: String, Identifiable {
        case arrive, destination, seal, update, documents, editNotes

        var id: String { rawValue }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let errorMessage { ErrorBanner(message: errorMessage) }

                if let detail {
                    summary(detail)
                    actions(detail)
                    contacts(detail)
                    history(detail)
                } else if loading {
                    ProgressView("Loading trip…").frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(16)
        }
        .screenBackground()
        .navigationTitle(detail?.trip.reference ?? "Trip")
        .navigationBarTitleDisplayMode(.inline)
        .lightBar()
        .refreshable { await load() }
        .task { await load() }
        .sheet(item: $sheet, onDismiss: { changed() }) { sheet in
            if let detail {
                switch sheet {
                case .arrive:
                    ArriveView(detail: detail) { _ in self.sheet = nil }
                case .destination:
                    DestinationPickerView(
                        tripId: detail.trip.id,
                        currentId: detail.destination?.id,
                        originId: detail.origin?.id
                    ) {}
                case .seal:
                    SealSheet(tripId: detail.trip.id, current: detail.trip.sealNumber) {}
                case .update:
                    SendUpdateSheet(trip: TripUpdateFields(detail))
                case .documents:
                    DocumentsSheet(scope: .trip(detail.trip.id), containerNumber: detail.container?.number, chassisNumber: detail.chassis?.number)
                case .editNotes:
                    EditTripNotesSheet(tripId: detail.trip.id, current: detail.trip.driverNotes ?? detail.trip.notes) {}
                }
            }
        }
        .fullScreenCover(isPresented: $resuming) {
            PickupWizardView(mode: .resume(tripId: tripId), model: model) { changed() }
        }
        .confirmationDialog("Cancel this trip?", isPresented: $confirmingCancel, titleVisibility: .visible) {
            Button("Cancel Trip", role: .destructive) { Task { await cancelTrip() } }
            Button("Keep Trip", role: .cancel) {}
        } message: {
            Text("The equipment goes back to where it was picked up.")
        }
        .confirmationDialog("Delete this trip?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Trip", role: .destructive) { Task { await deleteTrip() } }
            Button("Keep Trip", role: .cancel) {}
        } message: {
            Text("This trip will be removed from history. This cannot be undone.")
        }
        .confirmationDialog("Remove the swap tag?", isPresented: $confirmingUnswap, titleVisibility: .visible) {
            Button("Not a Swap", role: .destructive) { Task { await unswapTrip() } }
            Button("Keep as Swap", role: .cancel) {}
        } message: {
            Text("This clears the swap pairing on both this trip and the one it was linked to.")
        }
    }

    @ViewBuilder
    private func summary(_ detail: TripDetail) -> some View {
        let trip = detail.trip
        let sealEditable = !trip.isBareChassis && trip.isLive && (trip.isLoaded ?? false)
        TripCard(
            content: TripCard.Content(
                status: trip.status,
                isBareChassis: trip.isBareChassis || (detail.container?.number == nil && detail.chassis?.number != nil),
                containerNumber: detail.container?.number,
                chassisNumber: detail.chassis?.number,
                equipmentType: detail.container?.equipmentType,
                containerType: detail.container?.containerType,
                isLoaded: trip.isLoaded ?? false,
                sealNumber: trip.sealNumber,
                originName: detail.origin?.name,
                destinationName: detail.destination?.name
            ),
            onChangeDropoff: trip.isLive && trip.status != "PICKUP_IN_PROGRESS" ? { sheet = .destination } : nil,
            onEditSeal: sealEditable ? { sheet = .seal } : nil
        )

        let notes = trip.driverNotes ?? trip.notes
        if trip.pickedUpAt != nil || trip.droppedOffAt != nil || notes?.isEmpty == false {
            Card {
                InfoRow(label: "Picked up", value: trip.pickedUpAt.map { Format.dateTime($0) })
                InfoRow(label: "Dropped off", value: trip.droppedOffAt.map { Format.dateTime($0) })
                InfoRow(label: "Notes", value: notes)
            }
        }
    }

    /// The same next step Home offers for this trip, then everything else
    /// that can be done with it.
    @ViewBuilder
    private func actions(_ detail: TripDetail) -> some View {
        let trip = detail.trip
        if trip.isLive {
            if trip.status == "PICKUP_IN_PROGRESS" {
                Button("Continue Pickup") { resuming = true }
                    .buttonStyle(PrimaryButtonStyle())
            } else if detail.destination?.id != nil {
                Button("Arrive") { sheet = .arrive }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(working)
            } else {
                Button("Set Drop-off") { sheet = .destination }
                    .buttonStyle(PrimaryButtonStyle())
            }
        }

        HStack(spacing: 12) {
            Button {
                sheet = .documents
            } label: {
                Label("Documents", systemImage: "doc.text.fill")
            }
            .buttonStyle(SecondaryButtonStyle())

            Button {
                sheet = .update
            } label: {
                Label("Send Update", systemImage: "paperplane.fill")
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(TripUpdate.action(for: trip.status) == nil)
        }

        // Old trips and ones reconstructed from a missing-trip gap are
        // editable too, not just live ones — there is otherwise no way to
        // fix a note after the fact once a trip is finished.
        Button {
            sheet = .editNotes
        } label: {
            Label(trip.driverNotes?.isEmpty == false || trip.notes?.isEmpty == false ? "Edit Notes" : "Add Notes", systemImage: "pencil")
        }
        .buttonStyle(SecondaryButtonStyle())
        .disabled(trip.status == "CANCELLED")

        // "Swap" is set the moment that button is tapped to start the next
        // pickup — a shortcut to grab the container already sitting there,
        // not necessarily a same-visit hookup the driver meant to call a
        // swap. This is how to take the tag back off, on either half of it.
        if trip.swapPairTripId != nil {
            Button {
                confirmingUnswap = true
            } label: {
                Label("Not a Swap", systemImage: "arrow.left.arrow.right.circle")
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(working)
        }

        if trip.isLive {
            Button("Cancel Trip") { confirmingCancel = true }
                .buttonStyle(DangerTextButtonStyle())
                .disabled(working)
        } else {
            Button("Delete Trip") { confirmingDelete = true }
                .buttonStyle(DangerTextButtonStyle())
                .disabled(working)
        }
    }

    @ViewBuilder
    private func contacts(_ detail: TripDetail) -> some View {
        let places = [("Pickup", detail.origin), ("Drop-off", detail.destination)]
            .filter { ($0.1?.mainPhone?.isEmpty == false) || ($0.1?.contactPhone?.isEmpty == false) }
        if !places.isEmpty {
            SectionTitle(text: "Contacts")
            Card {
                ForEach(places, id: \.0) { label, place in
                    PhoneRow(label: "\(label) · \(place?.name ?? "") · Main", number: place?.mainPhone)
                    PhoneRow(label: "\(label) · \(place?.contactName ?? "Contact")", number: place?.contactPhone)
                }
            }
        }
    }

    @ViewBuilder
    private func history(_ detail: TripDetail) -> some View {
        let events = detail.timeline ?? []
        if !events.isEmpty {
            SectionTitle(text: "History")
            Card {
                ForEach(events) { event in
                    TimelineRow(
                        symbol: Words.eventSymbol(event.eventType),
                        title: Words.event(event),
                        lines: Self.lines(for: event),
                        date: event.occurredAt
                    )
                }
            }
        }
    }

    private static func lines(for event: TripEvent) -> [String] {
        var out: [String] = []
        if let place = event.locationName { out.append("At \(place)") }
        if let actor = event.actorName { out.append("By \(actor)") }
        if let chassis = event.chassisNumber { out.append("Chassis \(chassis)") }
        if let notes = event.notes { out.append(notes) }
        return out.filter { !$0.isEmpty }
    }

    private func changed() {
        onChanged()
        Task { await load() }
    }

    private func load() async {
        guard let api = model.api else { return }
        do {
            let loaded: TripDetail = try await api.get("/api/trips/\(tripId)")
            detail = loaded
            errorMessage = nil
        } catch {
            errorMessage = model.handle(error)
        }
        loading = false
    }

    private struct CancelBody: Encodable {
        let eventId: String
    }

    private func cancelTrip() async {
        guard let api = model.api else { return }
        working = true
        defer { working = false }
        do {
            // The id makes a retry on a weak signal count once.
            let _: OkResult = try await api.post("/api/trips/\(tripId)/cancel", body: CancelBody(eventId: UUID().uuidString.lowercased()))
            onChanged()
            await load()
        } catch {
            errorMessage = model.handle(error)
        }
    }

    private func deleteTrip() async {
        guard let api = model.api else { return }
        working = true
        defer { working = false }
        do {
            let _: OkResult = try await api.delete("/api/trips/\(tripId)")
            onChanged()
            dismiss()
        } catch {
            errorMessage = model.handle(error)
        }
    }

    private struct UnswapBody: Encodable {
        let unswap = true
    }

    private func unswapTrip() async {
        guard let api = model.api else { return }
        working = true
        defer { working = false }
        do {
            let _: OkResult = try await api.patch("/api/trips/\(tripId)", body: UnswapBody())
            await load()
            onChanged()
        } catch {
            errorMessage = model.handle(error)
        }
    }
}

/// Arrive at the drop-off. The server decides what the arrival does to the
/// container, chassis and duty cycle; this screen only asks the one question
/// the driver has to answer and sends it.
struct ArriveView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let detail: TripDetail
    /// Called when the sheet is finished with: true when the arrival was recorded.
    let onDone: (Bool) -> Void

    /// Same field the web app sends: for a container, true leaves the chassis
    /// under the box; for a bare chassis, true keeps it assigned to the driver.
    @State private var retainChassis: Bool?
    @State private var notes = ""
    @State private var submitting = false
    @State private var errorMessage: String?
    /// Kept for the life of the screen so a retry is not recorded twice.
    @State private var eventId = UUID().uuidString.lowercased()

    private var hasChassis: Bool { detail.trip.chassisId != nil }
    private var isBare: Bool { detail.trip.isBareChassis }
    private var canArrive: Bool {
        detail.destination?.id != nil && !submitting && (!hasChassis || retainChassis != nil)
    }

    private var placeSentence: String {
        if isBare { return "This trip ends here." }
        if detail.trip.swapPairTripId != nil && !(detail.trip.isLoaded ?? false) {
            return "This finishes the empty at the customer. The load stays on Home."
        }
        switch detail.destination?.type {
        case "CUSTOMER": return "The container stays at the customer to load. This trip ends."
        case "COMPANY_YARD": return "Yard stop. The container stays here. This trip ends."
        case "MARINE_TERMINAL", "RAIL_TERMINAL": return "The container is returned. This trip ends."
        default: return "This trip ends here."
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let errorMessage { ErrorBanner(message: errorMessage) }

                    Card {
                        Text("Arriving at")
                            .font(.footnote)
                            .foregroundColor(Brand.muted)
                        Text(detail.destination?.name ?? "No drop-off set")
                            .font(.title3.weight(.bold))
                            .foregroundColor(Brand.navy)
                        Text(Words.locationType(detail.destination?.type))
                            .font(.subheadline)
                            .foregroundColor(Brand.muted)
                        Divider()
                        InfoRow(label: "Container", value: detail.container?.number)
                        InfoRow(label: "Chassis", value: detail.chassis?.number)
                        Text(placeSentence)
                            .font(.subheadline)
                            .foregroundColor(Brand.navy)
                    }

                    if hasChassis {
                        SectionTitle(text: isBare ? "This chassis" : "Chassis")
                        choice(
                            title: isBare ? "Keep with you" : "Drop container + chassis",
                            detail: isBare ? "Stay assigned after this stop" : "Both stay at this location",
                            selected: retainChassis == true
                        ) { retainChassis = true }
                        choice(
                            title: isBare ? "Park here" : "Drop container only",
                            detail: isBare ? "Leave the chassis at this location" : "You keep the chassis for the next move. Home opens a chassis-only trip.",
                            selected: retainChassis == false
                        ) { retainChassis = false }
                    }

                    SectionTitle(text: "Notes (optional)")
                    TextField("Anything dispatch should know", text: $notes, axis: .vertical)
                        .lineLimit(2...5)
                        .padding(12)
                        .background(Brand.paper)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Brand.line))

                    Button(submitting ? "Recording…" : "Arrive") { Task { await arrive() } }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(!canArrive)
                }
                .padding(16)
            }
            .screenBackground()
            .navigationTitle("Arrive")
            .navigationBarTitleDisplayMode(.inline)
            .lightBar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private func choice(title: String, detail: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundColor(selected ? Brand.linkBlue : Brand.muted)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundColor(Brand.navy)
                    Text(detail).font(.footnote).foregroundColor(Brand.muted)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(Brand.paper)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(selected ? Brand.linkBlue : Brand.line, lineWidth: selected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private struct ArriveBody: Encodable {
        let eventId: String
        let destinationLocationId: String
        let retainChassis: Bool
        let notes: String?
        let gps: GpsFix?
    }

    private func arrive() async {
        guard let api = model.api, let destinationId = detail.destination?.id else { return }
        submitting = true
        errorMessage = nil
        defer { submitting = false }
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let _: OkResult = try await api.post(
                "/api/trips/\(detail.trip.id)/dropoff",
                body: ArriveBody(
                    eventId: eventId,
                    destinationLocationId: destinationId,
                    retainChassis: retainChassis == true,
                    notes: trimmed.isEmpty ? nil : trimmed,
                    gps: await LocationFix.shared.current()
                )
            )
            onDone(true)
        } catch {
            errorMessage = model.handle(error)
        }
    }
}

/// Arrive for a trip Home knows only by its id: fetch it, then ask.
struct ArriveSheet: View {
    @EnvironmentObject private var model: AppModel
    let tripId: String
    /// Called when the sheet is finished with: true when the arrival was recorded.
    let onDone: (Bool) -> Void

    @State private var detail: TripDetail?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let detail {
                ArriveView(detail: detail, onDone: onDone)
            } else if let errorMessage {
                VStack(spacing: 16) {
                    ErrorBanner(message: errorMessage)
                    Button("Close") { onDone(false) }.buttonStyle(SecondaryButtonStyle())
                }
                .padding(16)
            } else {
                ProgressView("Loading trip…")
            }
        }
        .task {
            guard let api = model.api else { return }
            do {
                let loaded: TripDetail = try await api.get("/api/trips/\(tripId)")
                detail = loaded
            } catch {
                errorMessage = model.handle(error)
            }
        }
    }
}

/// A month at a time, with a dot on every day that has a trip. Tapping a day
/// filters the list below, as the web app's calendar does.
private struct TripCalendar: View {
    let days: Set<Date>
    @Binding var selected: Date?

    @State private var month: Date = Calendar.current.startOfDay(for: Date())

    private var calendar: Calendar { Calendar.current }

    private var title: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "LLLL yyyy"
        return formatter.string(from: month)
    }

    /// Leading blanks so the first of the month lands under its weekday.
    private var cells: [Date?] {
        guard let first = calendar.date(from: calendar.dateComponents([.year, .month], from: month)),
              let range = calendar.range(of: .day, in: .month, for: first) else { return [] }
        let blanks = calendar.component(.weekday, from: first) - calendar.firstWeekday
        let leading = Array(repeating: Date?.none, count: (blanks + 7) % 7)
        return leading + range.compactMap { day in calendar.date(byAdding: .day, value: day - 1, to: first) }
    }

    private var weekdayNames: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let start = calendar.firstWeekday - 1
        return Array(symbols[start...] + symbols[..<start])
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Button {
                    step(-1)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .frame(minWidth: 44, minHeight: 36)
                .accessibilityLabel("Previous month")
                Spacer()
                Text(title)
                    .font(.headline)
                    .foregroundColor(Brand.navy)
                Spacer()
                Button {
                    step(1)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .frame(minWidth: 44, minHeight: 36)
                .accessibilityLabel("Next month")
            }
            .buttonStyle(.plain)
            .foregroundColor(Brand.linkBlue)

            HStack(spacing: 0) {
                ForEach(Array(weekdayNames.enumerated()), id: \.offset) { _, name in
                    Text(name)
                        .font(.caption2.weight(.bold))
                        .foregroundColor(Brand.muted)
                        .frame(maxWidth: .infinity)
                }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 4) {
                ForEach(Array(cells.enumerated()), id: \.offset) { _, day in
                    if let day {
                        dayCell(day)
                    } else {
                        Color.clear.frame(height: 42)
                    }
                }
            }
        }
        .padding(14)
        .cardSurface()
    }

    private func dayCell(_ day: Date) -> some View {
        let hasTrips = days.contains { calendar.isDate($0, inSameDayAs: day) }
        let isSelected = selected.map { calendar.isDate($0, inSameDayAs: day) } ?? false
        let isToday = calendar.isDateInToday(day)
        return Button {
            selected = isSelected ? nil : day
        } label: {
            VStack(spacing: 3) {
                Text("\(calendar.component(.day, from: day))")
                    .font(.subheadline.weight(isToday ? .bold : .semibold))
                    .foregroundColor(isSelected ? .white : (hasTrips ? Brand.navy : Brand.muted.opacity(0.7)))
                Circle()
                    .fill(hasTrips ? (isSelected ? Color.white : Brand.linkBlue) : .clear)
                    .frame(width: 5, height: 5)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .background(isSelected ? Brand.navy : (isToday ? Brand.skyWash : .clear))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!hasTrips)
        .accessibilityLabel(Format.day(day))
        .accessibilityHint(hasTrips ? "Has trips" : "No trips")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func step(_ months: Int) {
        if let next = calendar.date(byAdding: .month, value: months, to: month) { month = next }
    }
}
