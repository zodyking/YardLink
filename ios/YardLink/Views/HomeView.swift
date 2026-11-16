import SwiftUI

/// Driver home: the trip in hand, what to do next, and today's work. The
/// same screen as the web app's Home, with the same choices in the same
/// places; every action is carried out here on the phone.
struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    let user: SessionUser
    /// Switches to the Tasks tab.
    let openTasks: () -> Void

    @State private var home: HomePayload?
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var pickup: PickupLaunch?
    @State private var sheet: HomeSheet?
    @State private var confirmingCancel = false
    @State private var cancelling = false
    @AppStorage("home-cleared-trip") private var clearedTripId = ""

    /// A pickup to open: new, resumed, a swap, or a container for a bare chassis.
    private struct PickupLaunch: Identifiable {
        let id = UUID()
        let mode: PickupFlow.Mode
    }

    private enum HomeSheet: Identifiable {
        case messages
        case arrive(tripId: String)
        case destination(tripId: String, currentId: String?, originId: String?)
        case seal(tripId: String, current: String?)
        case update(trip: TripUpdateFields, dropped: TripUpdateFields?)
        case contacts(origin: NamedPlace?, destination: NamedPlace?)
        case documents(tripId: String, number: String?)

        var id: String {
            switch self {
            case .messages: return "messages"
            case .arrive(let tripId): return "arrive-\(tripId)"
            case .destination(let tripId, _, _): return "destination-\(tripId)"
            case .seal(let tripId, _): return "seal-\(tripId)"
            case .update(let trip, _): return "update-\(trip.tripId)"
            case .contacts: return "contacts"
            case .documents(let tripId, _): return "documents-\(tripId)"
            }
        }
    }

    /// What the big button does. The server decides which step is next and
    /// names it by the web app's address for that step.
    private enum NextAction {
        case newPickup
        case continuePickup(tripId: String)
        case setDropoff(HomePayload.Active)
        case arrive(tripId: String)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let errorMessage { ErrorBanner(message: errorMessage) }

                    if let home {
                        masthead(home)
                        trips(home)
                        actionGrid(home)
                        callsToAction(home)
                        dispatch(home)
                    } else if loading {
                        ProgressView("Loading your day…")
                            .frame(maxWidth: .infinity, minHeight: 240)
                    }
                }
                .padding(16)
            }
            .screenBackground()
            .navigationBarTitleDisplayMode(.inline)
            .navyBar()
            .toolbar {
                ToolbarItem(placement: .principal) { BrandMark() }
                ToolbarItem(placement: .navigationBarTrailing) { messagesButton }
            }
            .fullScreenCover(item: $pickup) { launch in
                PickupWizardView(mode: launch.mode, model: model) {
                    Task { await load() }
                }
            }
            .sheet(item: $sheet, onDismiss: { Task { await reloadAfterSheet() } }) { sheet in
                sheetContent(sheet)
            }
            .confirmationDialog("Cancel Trip", isPresented: $confirmingCancel, titleVisibility: .visible) {
                Button("Cancel Trip", role: .destructive) { Task { await cancelTrip() } }
                Button("Keep Trip", role: .cancel) {}
            } message: {
                Text(cancelCopy)
            }
            .refreshable { await load() }
            .task { await load() }
        }
    }

    // MARK: Sections

    private func masthead(_ home: HomePayload) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Hello \(home.driver.firstName)")
                .font(.title2.weight(.bold))
                .foregroundColor(Brand.navy)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 12) {
                tally(label: "Bridge Crosses", value: home.stats?.bridgeCrosses ?? 0)
                tally(label: "Swaps", value: home.stats?.swaps ?? 0)
            }
        }
    }

    private func tally(label: String, value: Int) -> some View {
        VStack(spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(0.8)
                .foregroundColor(Brand.muted)
            Text("\(value)")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundColor(Brand.navy)
        }
        .frame(maxWidth: .infinity, minHeight: 86)
        .cardSurface()
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func trips(_ home: HomePayload) -> some View {
        if let shown = displayTrip(home) {
            tripCard(shown, canChangeDropoff: home.active != nil)
            if let partner = home.swapPartner {
                Label("Swap", systemImage: "arrow.left.arrow.right")
                    .font(.subheadline.weight(.bold))
                    .foregroundColor(Brand.muted)
                    .frame(maxWidth: .infinity)
                tripCard(partner, canChangeDropoff: partner.trip.status != "PICKUP_IN_PROGRESS")
            }
        } else {
            VStack(spacing: 0) {
                VStack(spacing: 6) {
                    Text("No active trip")
                        .font(.system(size: 24, weight: .bold, design: .monospaced))
                        .foregroundColor(Brand.navy)
                    Text("Start a pickup to put a container on this card.")
                        .font(.subheadline)
                        .foregroundColor(Brand.muted)
                        .multilineTextAlignment(.center)
                }
                .padding(20)
                .frame(maxWidth: .infinity)
                RouteStrip(originName: nil, destinationName: nil)
            }
            .cardSurface()
        }
    }

    private func tripCard(_ active: HomePayload.Active, canChangeDropoff: Bool) -> some View {
        let trip = active.trip
        let sealEditable = !trip.isBareChassis && trip.isLive && (trip.isLoaded ?? false)
        return TripCard(
            content: TripCard.Content(
                status: trip.status,
                isBareChassis: trip.isBareChassis || (active.container?.number == nil && active.chassis?.number != nil),
                containerNumber: active.container?.number,
                chassisNumber: active.chassis?.number,
                equipmentType: active.container?.equipmentType,
                containerType: active.container?.containerType,
                isLoaded: trip.isLoaded ?? false,
                sealNumber: trip.sealNumber,
                originName: active.origin?.name,
                destinationName: active.destination?.name
            ),
            onChangeDropoff: canChangeDropoff
                ? { sheet = .destination(tripId: trip.id, currentId: active.destination?.id, originId: active.origin?.id) }
                : nil,
            onEditSeal: sealEditable ? { sheet = .seal(tripId: trip.id, current: trip.sealNumber) } : nil
        )
    }

    private func actionGrid(_ home: HomePayload) -> some View {
        let shown = displayTrip(home)
        let documentsTrip = loadTrip(home) ?? shown
        let update = updateFields(home)
        let swap = swapMode(home)

        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 12) {
            HomeAction(symbol: "doc.text.fill", title: "Documents", enabled: documentsTrip != nil) {
                if let trip = documentsTrip {
                    sheet = .documents(tripId: trip.trip.id, number: trip.container?.number ?? trip.chassis?.number)
                }
            }
            HomeAction(symbol: "paperplane.fill", title: "Send Update", enabled: update != nil) {
                if let update { sheet = .update(trip: update.trip, dropped: update.dropped) }
            }
            HomeAction(symbol: "phone.fill", title: "Contacts", enabled: shown != nil) {
                sheet = .contacts(origin: shown?.origin, destination: shown?.destination)
            }
            HomeAction(symbol: "arrow.left.arrow.right", title: "Swap", enabled: swap != nil) {
                if let swap { pickup = PickupLaunch(mode: swap) }
            }
        }
    }

    @ViewBuilder
    private func callsToAction(_ home: HomePayload) -> some View {
        VStack(spacing: 10) {
            if home.active == nil, let recent = displayTrip(home) {
                Button("Clear Trip") { clearedTripId = recent.trip.id }
                    .buttonStyle(PrimaryButtonStyle())
            } else {
                let next = nextStep(home)
                Button(next.label) { perform(next.action) }
                    .buttonStyle(PrimaryButtonStyle())
            }

            if let active = home.active, canAttachContainer(home) {
                Button("Add Container to Chassis") {
                    pickup = PickupLaunch(mode: .attach(tripId: active.trip.id, chassisNumber: active.chassis?.number ?? ""))
                }
                .buttonStyle(DarkButtonStyle())
            }

            if home.active != nil {
                Button(cancelling ? "Cancelling…" : "Cancel Trip") { confirmingCancel = true }
                    .buttonStyle(DangerTextButtonStyle())
                    .disabled(cancelling)
            }
        }
    }

    @ViewBuilder
    private func dispatch(_ home: HomePayload) -> some View {
        let tasks = home.todayTasks ?? []
        if !tasks.isEmpty {
            HStack {
                SectionTitle(text: "Dispatch")
                Button("All Tasks", action: openTasks)
                    .font(.subheadline.weight(.semibold))
            }
            ForEach(tasks) { task in
                Button(action: openTasks) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: task.status == "DONE" ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundColor(task.status == "DONE" ? Brand.ok : Brand.linkBlue)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(task.title?.isEmpty == false ? (task.title ?? "") : Words.taskKind(task.kind))
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(Brand.navy)
                                .multilineTextAlignment(.leading)
                            if let line = taskLine(task) {
                                Text(line)
                                    .font(.footnote)
                                    .foregroundColor(Brand.muted)
                                    .multilineTextAlignment(.leading)
                            }
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundColor(Brand.muted.opacity(0.6))
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardSurface()
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func taskLine(_ task: HomePayload.TodayTask) -> String? {
        guard let card = task.card else { return nil }
        let route = [card.locationName, card.destinationLocationName]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " to ")
        let box = Marking.formatContainer(card.containerNumber)
        let parts = [box, route].filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var messagesButton: some View {
        Button {
            sheet = .messages
        } label: {
            Image(systemName: model.unreadMessages > 0 ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right")
                .overlay(alignment: .topTrailing) {
                    if model.unreadMessages > 0 {
                        Text(model.unreadMessages > 9 ? "9+" : "\(model.unreadMessages)")
                            .font(.caption2.weight(.bold))
                            .foregroundColor(.white)
                            .padding(4)
                            .background(Brand.danger)
                            .clipShape(Capsule())
                            .offset(x: 12, y: -9)
                    }
                }
        }
        .tint(.white)
        .accessibilityLabel(model.unreadMessages > 0 ? "Messages, \(model.unreadMessages) unread" : "Messages")
    }

    @ViewBuilder
    private func sheetContent(_ sheet: HomeSheet) -> some View {
        switch sheet {
        case .messages:
            MessagesView(user: user)
        case .arrive(let tripId):
            ArriveSheet(tripId: tripId) { self.sheet = nil }
        case .destination(let tripId, let currentId, let originId):
            DestinationPickerView(tripId: tripId, currentId: currentId, originId: originId) {}
        case .seal(let tripId, let current):
            SealSheet(tripId: tripId, current: current) {}
        case .update(let trip, let dropped):
            SendUpdateSheet(trip: trip, swapDropped: dropped)
        case .contacts(let origin, let destination):
            ContactsSheet(origin: origin, destination: destination)
        case .documents(let tripId, let number):
            DocumentsSheet(scope: .trip(tripId), equipmentNumber: number)
        }
    }

    // MARK: What Home shows

    /// The live trip, or one finished in the last few hours until it is cleared.
    private func displayTrip(_ home: HomePayload) -> HomePayload.Active? {
        if let active = home.active { return active }
        guard let recent = home.recentCompleted, recent.trip.id != clearedTripId else { return nil }
        return recent
    }

    private func loadTrip(_ home: HomePayload) -> HomePayload.Active? {
        if let active = home.active, active.trip.isLoaded ?? false { return active }
        if let partner = home.swapPartner, partner.trip.isLoaded ?? false { return partner }
        return nil
    }

    private func emptyTrip(_ home: HomePayload) -> HomePayload.Active? {
        if let active = home.active, !(active.trip.isLoaded ?? false), !active.trip.isBareChassis { return active }
        if let partner = home.swapPartner, !(partner.trip.isLoaded ?? false) { return partner }
        return nil
    }

    /// The update that can be sent now: both halves of a swap, or one trip.
    private func updateFields(_ home: HomePayload) -> (trip: TripUpdateFields, dropped: TripUpdateFields?)? {
        if let load = loadTrip(home), let empty = emptyTrip(home), load.trip.id != empty.trip.id,
           TripUpdate.action(for: load.trip.status) != nil, TripUpdate.action(for: empty.trip.status) != nil {
            return (TripUpdateFields(load), TripUpdateFields(empty))
        }
        guard let shown = displayTrip(home), TripUpdate.action(for: shown.trip.status) != nil else { return nil }
        return (TripUpdateFields(shown), nil)
    }

    /// An empty inbound to a customer can open a second pickup for the load.
    private func swapMode(_ home: HomePayload) -> PickupFlow.Mode? {
        if let partner = home.swapPartner, partner.trip.status == "PICKUP_IN_PROGRESS" {
            return .resume(tripId: partner.trip.id)
        }
        guard let active = home.active else { return nil }
        let trip = active.trip
        if trip.status == "PICKUP_IN_PROGRESS", trip.swapPairTripId != nil {
            return .resume(tripId: trip.id)
        }
        let canSwap = trip.swapPairTripId == nil
            && !trip.isBareChassis
            && !(trip.isLoaded ?? false)
            && active.destination?.type == "CUSTOMER"
            && (trip.status == "IN_TRANSIT" || trip.status == "DROPOFF_IN_PROGRESS")
        return canSwap ? .swap(ofTripId: trip.id) : nil
    }

    private func canAttachContainer(_ home: HomePayload) -> Bool {
        guard let active = home.active, home.swapPartner == nil else { return false }
        return active.chassis?.number != nil
            && active.container?.number == nil
            && active.trip.status != "PICKUP_IN_PROGRESS"
    }

    private func nextStep(_ home: HomePayload) -> (label: String, action: NextAction) {
        guard let active = home.active else { return ("New Pickup", .newPickup) }
        let label = active.primaryAction?.label ?? "Open Trip"
        let target = URLComponents(string: active.primaryAction?.to ?? "")
        let parts = (target?.path ?? "").split(separator: "/").map(String.init)

        if let tripId = target?.queryItems?.first(where: { $0.name == "trip" })?.value {
            return (label, .continuePickup(tripId: tripId))
        }
        if parts.count == 3, parts[0] == "trips" {
            let subject = [active, home.swapPartner].compactMap { $0 }.first { $0.trip.id == parts[1] } ?? active
            if parts[2] == "destination" { return (label, .setDropoff(subject)) }
            if parts[2] == "dropoff" { return (label, .arrive(tripId: subject.trip.id)) }
        }
        // An address this version does not know: fall back on the trip's own state.
        if active.trip.status == "PICKUP_IN_PROGRESS" { return ("Continue Pickup", .continuePickup(tripId: active.trip.id)) }
        if active.destination?.id == nil { return ("Set Drop-off", .setDropoff(active)) }
        return ("Arrive", .arrive(tripId: active.trip.id))
    }

    private func perform(_ action: NextAction) {
        switch action {
        case .newPickup:
            pickup = PickupLaunch(mode: .new)
        case .continuePickup(let tripId):
            pickup = PickupLaunch(mode: .resume(tripId: tripId))
        case .setDropoff(let active):
            sheet = .destination(tripId: active.trip.id, currentId: active.destination?.id, originId: active.origin?.id)
        case .arrive(let tripId):
            sheet = .arrive(tripId: tripId)
        }
    }

    private var cancelCopy: String {
        guard let home else { return "" }
        if home.active != nil && home.swapPartner != nil {
            return "Cancel the swap pickup? The empty inbound stays active."
        }
        if home.active?.container?.number == nil {
            return "Cancel this trip? You will go back to no active trip. The chassis returns to available."
        }
        return "Cancel this trip? You will go back to no active trip. The container stays in the pool."
    }

    // MARK: Server

    private func load() async {
        guard let api = model.api else { return }
        do {
            let payload: HomePayload = try await api.get("/api/home")
            home = payload
            errorMessage = nil
        } catch {
            errorMessage = model.handle(error)
        }
        loading = false
    }

    private func reloadAfterSheet() async {
        await load()
        await model.refreshUnread()
    }

    private struct CancelPayload: Encodable {
        let eventId: String
        let reason: String
    }

    private func cancelTrip() async {
        guard let api = model.api, let home, let active = home.active, !cancelling else { return }
        let inSwap = home.swapPartner != nil
        let target = inSwap ? (loadTrip(home) ?? home.swapPartner ?? active) : active
        cancelling = true
        defer { cancelling = false }
        do {
            let _: OkResult = try await api.post("/api/trips/\(target.trip.id)/cancel", body: CancelPayload(
                eventId: UUID().uuidString.lowercased(),
                reason: inSwap ? "Driver cancelled the swap pickup from Home." : "Driver cancelled from Home."
            ))
            await load()
        } catch {
            errorMessage = model.handle(error)
        }
    }
}

/// One of the four squares under the trip card.
private struct HomeAction: View {
    let symbol: String
    let title: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(enabled ? Brand.linkBlue : Brand.muted.opacity(0.5))
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(enabled ? Brand.ink : Brand.muted.opacity(0.6))
            }
            .frame(maxWidth: .infinity, minHeight: 68)
            .cardSurface(radius: Brand.controlRadius)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}
