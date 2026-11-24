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
    /// A fresh swap pairing waiting on a yes before it's actually started.
    @State private var pendingSwap: PickupFlow.Mode?
    @State private var sheet: HomeSheet?
    @State private var confirmingCancel = false
    @State private var cancelling = false
    @ObservedObject private var push = PushCenter.shared
    @ObservedObject private var arrivals = ArrivalWatch.shared
    @ObservedObject private var rootTap = TabRootTap.shared
    @State private var path = NavigationPath()
    /// Trips the driver has cleared off Home, newest last. A list rather than
    /// one id, so an older trip cannot reappear when something touches it.
    @AppStorage("home-cleared-trips") private var clearedTripIds = ""
    /// The trip whose arrival was just recorded, so the button becomes Clear
    /// Trip at once instead of after the next load.
    @State private var arrivedTripId: String?
    /// Tasks just completed from Home, with where each sat in the list. They
    /// stay on screen with an Undo for a minute, since the server stops
    /// listing a task the moment it is done.
    @State private var justDone: [JustDone] = []
    @State private var taskError: String?

    /// How long a completed task keeps its Undo.
    private static let undoWindow: UInt64 = 60

    private struct JustDone: Identifiable {
        let task: HomePayload.TodayTask
        let index: Int
        var id: String { task.id }
    }

    private struct TaskStatusBody: Encodable { let status: String }
    private struct TaskStepsBody: Encodable { let steps: [TaskStep] }

    /// A pickup to open: new, resumed, a swap, or a container for a bare chassis.
    private struct PickupLaunch: Identifiable {
        let id = UUID()
        let mode: PickupFlow.Mode
    }

    private enum HomeSheet: Identifiable {
        case messages
        case tools
        case arrive(tripId: String)
        case destination(tripId: String, currentId: String?, originId: String?)
        case seal(tripId: String, current: String?)
        case update(trip: TripUpdateFields, dropped: TripUpdateFields?)
        case contacts(origin: NamedPlace?, destination: NamedPlace?)
        case documents

        var id: String {
            switch self {
            case .messages: return "messages"
            case .tools: return "tools"
            case .arrive(let tripId): return "arrive-\(tripId)"
            case .destination(let tripId, _, _): return "destination-\(tripId)"
            case .seal(let tripId, _): return "seal-\(tripId)"
            case .update(let trip, _): return "update-\(trip.tripId)"
            case .contacts: return "contacts"
            case .documents: return "documents"
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
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let errorMessage { ErrorBanner(message: errorMessage) }
                    if let question = arrivals.question { arrivalCard(question) }

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
                .padding(.horizontal, 16)
                .padding(.top, 16)
                // Extra clearance so the last button in view (e.g. Cancel
                // Trip, when there's little else on the page) never sits
                // under the raised Tasks disc in the tab bar below, which
                // paints above its own bar by design. The bar itself is
                // untouched; this just keeps content clear of where it
                // paints.
                .padding(.bottom, 44)
            }
            .screenBackground()
            .brandScreen(leading: { toolsButton }) { messagesButton }
            .fullScreenCover(item: $pickup) { launch in
                PickupWizardView(mode: launch.mode, model: model) {
                    Task { await load() }
                }
            }
            .sheet(item: $sheet, onDismiss: { Task { await reloadAfterSheet() } }) { sheet in
                sheetContent(sheet)
            }
            .confirmPrompt(
                "Cancel Trip",
                message: cancelCopy,
                isPresented: $confirmingCancel,
                cancelLabel: "Keep Trip",
                actions: [.destructive("Cancel Trip") { Task { await cancelTrip() } }]
            )
            .confirmPrompt(
                "Start this as a swap?",
                message: "This links the next load to the empty you're dropping here, and marks both trips as a swap in history. If you're not hooking up and driving off right now, start a plain new pickup instead once you've arrived.",
                isPresented: Binding(get: { pendingSwap != nil }, set: { if !$0 { pendingSwap = nil } }),
                cancelLabel: "Just a New Pickup",
                actions: [.primary("Yes, Pair With This Drop-off") {
                    if let pendingSwap { pickup = PickupLaunch(mode: pendingSwap) }
                    pendingSwap = nil
                }]
            )
            .refreshable { await load() }
            .task { await load() }
            .onChange(of: push.openScreen) { screen in
                // A tapped message notice opens Messages over Home.
                guard screen == "messages" else { return }
                sheet = .messages
                push.openScreen = nil
            }
            .onChange(of: rootTap.event) { event in
                // Tapping Home again while already on Home pops back to it.
                guard event?.screen == AnyHashable(MainTabs.Screen.home) else { return }
                path = NavigationPath()
            }
        }
    }

    // MARK: Sections

    private func masthead(_ home: HomePayload) -> some View {
        VStack(spacing: 12) {
            PageTitle(text: home.driver.firstName.map { "Hello \($0)" } ?? "Home", alignment: .center)
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
        let update = updateFields(home)
        let swap = swapMode(home)

        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 12) {
            HomeAction(symbol: "doc.text.fill", title: "Documents", enabled: true) {
                sheet = .documents
            }
            HomeAction(symbol: "paperplane.fill", title: "Send Update", enabled: update != nil) {
                if let update { sheet = .update(trip: update.trip, dropped: update.dropped) }
            }
            HomeAction(symbol: "phone.fill", title: "Contacts", enabled: shown != nil) {
                sheet = .contacts(origin: shown?.origin, destination: shown?.destination)
            }
            HomeAction(symbol: "arrow.left.arrow.right", title: "Swap", enabled: swap != nil) {
                guard let swap else { return }
                // Resuming one already in progress needs no fresh say-so;
                // only pairing a brand new load asks first, since tapping
                // this used to be the only "determination" a swap ever got.
                if case .swap = swap {
                    pendingSwap = swap
                } else {
                    pickup = PickupLaunch(mode: swap)
                }
            }
        }
    }

    @ViewBuilder
    private func callsToAction(_ home: HomePayload) -> some View {
        VStack(spacing: 10) {
            let main = mainButton(home)
            Button(main.label) { main.act() }
                .buttonStyle(PrimaryButtonStyle())

            if let active = home.active, canAttachContainer(home), arrivedTripId != active.trip.id {
                Button("Add Container to Chassis") {
                    pickup = PickupLaunch(mode: .attach(tripId: active.trip.id, chassisNumber: active.chassis?.number ?? ""))
                }
                .buttonStyle(DarkButtonStyle())
            }

            if let active = home.active, arrivedTripId != active.trip.id {
                Button(cancelling ? "Cancelling…" : "Cancel Trip") { confirmingCancel = true }
                    .buttonStyle(DangerTextButtonStyle())
                    .disabled(cancelling)
            }
        }
    }

    @ViewBuilder
    private func dispatch(_ home: HomePayload) -> some View {
        let tasks = dispatchRows(home.todayTasks ?? [])
        if !tasks.isEmpty {
            HStack {
                SectionTitle(text: "Dispatch")
                Button("All Tasks", action: openTasks)
                    .font(.subheadline.weight(.semibold))
            }
            if let taskError { ErrorBanner(message: taskError) }
            ForEach(tasks) { task in
                let finished = justDone.contains { $0.id == task.id }
                HStack(alignment: .top, spacing: 12) {
                    Button {
                        Task { await finish(task, from: tasks) }
                    } label: {
                        Image(systemName: finished ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundColor(finished ? Brand.ok : Brand.linkBlue)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .disabled(finished)
                    .accessibilityLabel(finished ? "Done" : "Mark done")

                    Button(action: openTasks) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(task.title?.isEmpty == false ? (task.title ?? "") : Words.taskKind(task.kind))
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(finished ? Brand.muted : Brand.navy)
                                .strikethrough(finished, color: Brand.muted)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            if let line = taskLine(task) {
                                Text(line)
                                    .font(.footnote)
                                    .foregroundColor(Brand.muted)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)

                    if finished {
                        Button("Undo") { Task { await undo(task.id) } }
                            .font(.subheadline.weight(.bold))
                            .foregroundColor(Brand.linkBlue)
                            .frame(minHeight: 32)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundColor(Brand.muted.opacity(0.6))
                            .padding(.top, 8)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardSurface()
            }
        }
    }

    /// The server's open tasks with the just-completed ones put back where
    /// they were, so a finished task does not jump out from under the thumb.
    private func dispatchRows(_ open: [HomePayload.TodayTask]) -> [HomePayload.TodayTask] {
        var rows = open.filter { task in !justDone.contains { $0.id == task.id } }
        for item in justDone.sorted(by: { $0.index < $1.index }) {
            rows.insert(item.task, at: min(item.index, rows.count))
        }
        return rows
    }

    private func finish(_ task: HomePayload.TodayTask, from rows: [HomePayload.TodayTask]) async {
        guard let api = model.api else { return }
        taskError = nil
        do {
            let _: TaskEnvelope = try await api.patch("/api/tasks/\(task.id)", body: TaskStatusBody(status: "DONE"))
        } catch {
            taskError = model.handle(error)
            return
        }
        justDone.append(JustDone(task: task, index: rows.firstIndex { $0.id == task.id } ?? rows.count))
        Task {
            try? await Task.sleep(nanoseconds: Self.undoWindow * 1_000_000_000)
            guard justDone.contains(where: { $0.id == task.id }) else { return }
            justDone.removeAll { $0.id == task.id }
            await load()
        }
    }

    /// Reopen a task. Marking done ticks every step, so the steps go back as
    /// they were; a task with no steps just reopens.
    private func undo(_ id: String) async {
        guard let api = model.api, let item = justDone.first(where: { $0.id == id }) else { return }
        taskError = nil
        do {
            if let steps = item.task.steps, !steps.isEmpty {
                let _: TaskEnvelope = try await api.patch("/api/tasks/\(id)", body: TaskStepsBody(steps: steps))
            } else {
                let _: TaskEnvelope = try await api.patch("/api/tasks/\(id)", body: TaskStatusBody(status: "OPEN"))
            }
        } catch {
            taskError = model.handle(error)
            return
        }
        justDone.removeAll { $0.id == id }
        await load()
    }

    /// The live trip's container, for Tools > Check CSX.
    private var toolsTripContainer: ToolsView.TripContainer? {
        guard let box = home?.active?.container, let id = box.id, let number = box.number, !number.isEmpty else { return nil }
        return ToolsView.TripContainer(id: id, number: number)
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
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 44, height: 44)
                .overlay(alignment: .topTrailing) {
                    if model.unreadMessages > 0 {
                        Text(model.unreadMessages > 9 ? "9+" : "\(model.unreadMessages)")
                            .font(.caption2.weight(.bold))
                            .foregroundColor(.white)
                            .padding(4)
                            .background(Brand.danger)
                            .clipShape(Capsule())
                            .offset(x: -4, y: 4)
                    }
                }
        }
        .accessibilityLabel(model.unreadMessages > 0 ? "Messages, \(model.unreadMessages) unread" : "Messages")
    }

    private var toolsButton: some View {
        Button {
            sheet = .tools
        } label: {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel("Tools")
    }

    @ViewBuilder
    private func sheetContent(_ sheet: HomeSheet) -> some View {
        Group {
            switch sheet {
            case .messages:
                MessagesView(user: user)
            case .tools:
                ToolsView(
                    bridgeCrossingTimesEnabled: home?.bridgeCrossingTimesEnabled ?? false,
                    tripContainer: toolsTripContainer
                )
            case .arrive(let tripId):
                ArriveSheet(tripId: tripId) { arrived in
                    if arrived { arrivedTripId = tripId }
                    self.sheet = nil
                }
            case .destination(let tripId, let currentId, let originId):
                DestinationPickerView(tripId: tripId, currentId: currentId, originId: originId) {}
            case .seal(let tripId, let current):
                SealSheet(tripId: tripId, current: current) {}
            case .update(let trip, let dropped):
                SendUpdateSheet(trip: trip, swapDropped: dropped)
            case .contacts(let origin, let destination):
                ContactsSheet(origin: origin, destination: destination)
            case .documents:
                DriverDocumentsSheet()
            }
        }
        .sheetChrome()
    }

    // MARK: What Home shows

    /// The live trip, or one finished in the last few hours until it is cleared.
    private func displayTrip(_ home: HomePayload) -> HomePayload.Active? {
        if let active = home.active { return active }
        guard let recent = home.recentCompleted, !cleared.contains(recent.trip.id) else { return nil }
        return recent
    }

    private var cleared: [String] {
        clearedTripIds.split(separator: ",").map(String.init)
    }

    /// Take the trip off Home and remember that, so it stays off.
    private func clearFromHome(_ tripId: String) {
        var kept = cleared.filter { $0 != tripId }
        kept.append(tripId)
        clearedTripIds = kept.suffix(20).joined(separator: ",")
        arrivedTripId = nil
    }

    /// The one button at the foot of Home. It follows the trip the whole way:
    /// continue the pickup, set the drop-off, arrive — and once the equipment
    /// is down, the same button clears the finished trip away.
    private func mainButton(_ home: HomePayload) -> (label: String, act: () -> Void) {
        if let shown = displayTrip(home), home.active == nil || arrivedTripId == shown.trip.id {
            let tripId = shown.trip.id
            return ("Clear Trip", { clearFromHome(tripId) })
        }
        let next = nextStep(home)
        return (next.label, { perform(next.action) })
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
            WidgetSync.update(home: payload)
            home = payload
            // The server has caught up with the arrival; the button can go
            // back to following the payload on its own.
            if payload.active?.trip.id != arrivedTripId { arrivedTripId = nil }
            errorMessage = nil
            watchArrivalCircle(payload)
            await arrivals.refresh()
        } catch {
            errorMessage = model.handle(error)
        }
        loading = false
    }

    /// The circle to watch is the live trip's drop-off, and only while the
    /// trip is live — a finished day leaves nothing running in the background.
    private func watchArrivalCircle(_ payload: HomePayload) {
        let live = payload.active?.trip.isLive == true ? payload.active : nil
        ArrivalWatch.shared.watch(destination: live?.destination)
    }

    private func arrivalCard(_ question: ArrivalQuestion) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Arrived at \(question.locationName)?")
                .font(.headline)
                .foregroundColor(Brand.navy)
            Text("Yard Link records the arrival on its own shortly, stamped when you pulled in.")
                .font(.footnote)
                .foregroundColor(Brand.muted)
            HStack(spacing: 12) {
                Button("Yes, I'm here") {
                    Task { await arrivals.answer(question, arrived: true) }
                }
                .buttonStyle(PrimaryButtonStyle())
                Button("Not yet") {
                    Task { await arrivals.answer(question, arrived: false) }
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(16)
        .cardSurface()
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
