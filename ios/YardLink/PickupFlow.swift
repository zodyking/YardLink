import SwiftUI
import UIKit

/// Everything a pickup asks, in order, and what has been answered so far.
///
/// The steps and their order are the web app's. The phone holds the answers
/// and sends them; the server claims the equipment, opens the trip and
/// decides what the pickup does to the container's history.
@MainActor
final class PickupFlow: ObservableObject {
    enum Mode: Equatable {
        case new
        /// Carry on with a pickup that was started and not confirmed.
        case resume(tripId: String)
        /// Second pickup of a load while an empty is inbound to a customer.
        case swap(ofTripId: String)
        /// Hang a container on the chassis of a live bare-chassis trip.
        case attach(tripId: String, chassisNumber: String)
    }

    enum Step: Int, CaseIterable {
        case kind, location, inventory, equipment, containerType, equipmentType, seal, notes, destination, confirm
    }

    /// A yes-or-no question that has to be answered before the step can go on.
    struct Question: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let confirmLabel: String
    }

    // MARK: Answers

    @Published private(set) var step: Step
    @Published private(set) var kind: String?
    @Published private(set) var originId: String?
    @Published private(set) var originName = ""
    @Published private(set) var destinationId: String?
    @Published private(set) var destinationName = ""
    @Published private(set) var selectedYardId: String?
    @Published private(set) var manualEntry = false
    @Published private(set) var number = ""
    @Published private(set) var chassisNumber = ""
    @Published private(set) var containerType: String?
    @Published private(set) var equipmentType: String?
    @Published var isLoaded: Bool? { didSet { reconcileStep() } }
    @Published var sealNumber = ""
    @Published var notes = ""
    @Published var locationSearch = ""
    @Published var inventorySearch = ""

    // MARK: What the server said

    @Published private(set) var locations: [LocationListItem] = []
    @Published private(set) var locationsLoading = true
    @Published private(set) var inventory: SiteInventory?
    @Published private(set) var inventoryLoading = false
    @Published private(set) var resolution: PoolResolution?
    @Published private(set) var resolving = false
    @Published private(set) var tripId: String?
    /// A pickup already in progress that this one would collide with.
    @Published private(set) var existingTripId: String?

    // MARK: Screen state

    @Published private(set) var loading = false
    @Published private(set) var submitting = false
    @Published private(set) var readingPhoto = false
    @Published private(set) var photo: UIImage?
    @Published var errorMessage: String?
    @Published private(set) var photoMessage: String?
    @Published var question: Question?
    /// Set when the pickup is confirmed or given up; the screen closes.
    @Published private(set) var finished = false

    let mode: Mode
    private let model: AppModel
    private var chassisId: String?
    private var savedDestinationId: String?
    private var swapOfTripId: String?
    private var attachTripId: String?
    private var promptedHoldFor = ""
    private var answer: CheckedContinuation<Bool, Never>?
    private var resolveTask: Task<Void, Never>?

    init(mode: Mode, model: AppModel) {
        self.mode = mode
        self.model = model
        switch mode {
        case .new, .resume:
            step = .kind
        case .swap(let tripId):
            step = .inventory
            swapOfTripId = tripId
            kind = "CONTAINER"
            isLoaded = true
        case .attach(let tripId, let chassis):
            step = .equipment
            attachTripId = tripId
            kind = "CONTAINER"
            manualEntry = true
            chassisNumber = Marking.maskChassis(chassis)
        }
    }

    // MARK: Derived

    var isAttach: Bool { attachTripId != nil }
    var isSwap: Bool { swapOfTripId != nil }
    var isBareChassis: Bool { kind == "BARE_CHASSIS" }
    var fromYard: Bool { selectedYardId != nil && !manualEntry }
    var needsClassification: Bool { resolution?.outcome == "CREATE" }
    var blockedByConflict: Bool { resolution?.outcome == "CONFLICT" }
    var check: Marking.ContainerCheck { Marking.checkContainer(number) }
    var chassisOk: Bool {
        if isBareChassis { return Marking.isCompleteChassis(chassisNumber) }
        return chassisNumber.isEmpty || Marking.isCompleteChassis(chassisNumber)
    }

    /// The steps this pickup needs, given the answers so far. Choosing
    /// equipment already at the yard skips everything its record answers.
    var steps: [Step] {
        if isAttach {
            var list: [Step] = [.equipment]
            if needsClassification { list += [.containerType, .equipmentType] }
            if isLoaded == true { list.append(.seal) }
            list.append(.confirm)
            return list
        }

        var list: [Step] = isSwap ? [.inventory] : [.kind, .location, .inventory]
        if manualEntry && !fromYard {
            list.append(.equipment)
            if kind == "CONTAINER" && needsClassification { list += [.containerType, .equipmentType] }
        }
        if kind == "CONTAINER" && isLoaded == true && (manualEntry || fromYard) { list.append(.seal) }
        list.append(.notes)
        if !isSwap { list.append(.destination) }
        list.append(.confirm)
        return list
    }

    var stepIndex: Int { steps.firstIndex(of: step) ?? 0 }
    var progress: Double { Double(stepIndex + 1) / Double(max(steps.count, 1)) }

    /// The step at which the equipment is claimed and the trip is opened.
    private var claimStep: Step {
        if fromYard { return .inventory }
        if isBareChassis { return .equipment }
        return needsClassification ? .equipmentType : .equipment
    }

    /// Once the trip is open the equipment is claimed; going back to change
    /// it means cancelling the pickup, which releases it.
    var canGoBack: Bool {
        guard stepIndex > 0 else { return false }
        guard tripId != nil else { return true }
        return [.seal, .notes, .destination].contains(steps[stepIndex - 1])
    }

    var title: String {
        switch step {
        case .kind: return "New Pickup"
        case .location: return "Pickup Location"
        case .inventory:
            if isSwap { return "Which Load?" }
            return isBareChassis ? "Which Chassis?" : "Which Container?"
        case .equipment:
            if isAttach { return "Add Container" }
            if isSwap { return "Load and Chassis" }
            return isBareChassis ? "Chassis" : "Container and Chassis"
        case .containerType: return "Container Type"
        case .equipmentType: return "Container Size"
        case .seal: return "Seal"
        case .notes: return "Notes"
        case .destination: return "Drop-off"
        case .confirm: return isAttach ? "Hang the Container" : "Confirm"
        }
    }

    /// Steps answered by tapping a row have no button at the bottom.
    var showsContinue: Bool {
        switch step {
        case .kind, .location, .inventory, .destination, .confirm: return false
        case .containerType, .equipmentType: return tripId != nil
        case .equipment, .seal, .notes: return true
        }
    }

    var canContinue: Bool {
        guard !submitting, !readingPhoto else { return false }
        switch step {
        case .equipment:
            if isBareChassis { return chassisOk }
            return check.structureValid && chassisOk && (isSwap || isLoaded != nil)
                && !blockedByConflict && !resolving && resolution != nil
        case .containerType: return containerType != nil
        case .equipmentType: return equipmentType != nil
        case .seal: return !sealNumber.trimmingCharacters(in: .whitespaces).isEmpty
        case .notes: return true
        default: return false
        }
    }

    var canConfirm: Bool {
        guard !submitting, kind != nil else { return false }
        if isAttach { return containerType != nil && equipmentType != nil && isLoaded != nil }
        guard tripId != nil, isSwap || destinationId != nil else { return false }
        if kind == "CONTAINER" {
            return containerType != nil && equipmentType != nil && (isSwap || isLoaded != nil)
        }
        return true
    }

    var originOptions: [LocationListItem] { Self.filter(locations, by: locationSearch) }
    var destinationOptions: [LocationListItem] {
        Self.filter(locations.filter { $0.id != originId }, by: locationSearch)
    }

    private static func filter(_ items: [LocationListItem], by search: String) -> [LocationListItem] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return items }
        return items.filter { item in
            item.name.lowercased().contains(needle)
                || (item.addressLine1 ?? "").lowercased().contains(needle)
                || (item.city ?? "").lowercased().contains(needle)
        }
    }

    private var inventoryNeedle: String { Marking.normalize(inventorySearch) }

    /// Containers on site, then the ones on this location's CSX pickup list
    /// that are not already here.
    var yardContainers: [YardBox] {
        let onSite = inventory?.containers ?? []
        var seen = Set(onSite.map { Marking.normalize($0.numberNormalized ?? $0.number) })
        var all = onSite
        for release in inventory?.csxReleases ?? [] where seen.insert(Marking.normalize(release.numberNormalized ?? release.number)).inserted {
            all.append(release)
        }
        let needle = inventoryNeedle
        guard !needle.isEmpty else { return all }
        return all.filter { item in
            Marking.normalize(item.numberNormalized ?? item.number).contains(needle)
                || Marking.normalize(item.pickupNumber ?? "").contains(needle)
        }
    }

    var yardChassis: [YardChassis] {
        let items = inventory?.chassis ?? []
        let needle = inventoryNeedle
        guard !needle.isEmpty else { return items }
        return items.filter { item in
            Marking.normalize(item.number).contains(needle) || Marking.normalize(item.provider ?? "").contains(needle)
        }
    }

    // MARK: Start

    /// Load what the first screen needs, and pick up where an unfinished
    /// pickup left off.
    func start() async {
        guard let api = model.api else { return }
        loading = true
        defer { loading = false }

        if !isAttach {
            do {
                let list: LocationList = try await api.get("/api/locations", query: ["limit": "200", "lite": "1"])
                locations = list.items.filter { !($0.isUncategorized ?? false) }
            } catch {
                errorMessage = model.handle(error)
            }
            locationsLoading = false
        }

        switch mode {
        case .resume(let id):
            await hydrate(from: id)
        case .swap(let id):
            await loadSwapSite(for: id)
            await findUnfinishedPickup()
        case .new:
            await findUnfinishedPickup()
        case .attach:
            break
        }
    }

    private func findUnfinishedPickup() async {
        guard let api = model.api else { return }
        // A convenience, not a blocker: a failure here changes nothing.
        guard let live: TripList = try? await api.get("/api/trips", query: ["scope": "mine", "status": "PICKUP_IN_PROGRESS", "limit": "1"]),
              let liveId = live.items.first?.id, liveId != tripId else { return }

        if let swapOfTripId,
           let open: TripDetail = try? await api.get("/api/trips/\(liveId)"),
           open.trip.swapPairTripId == swapOfTripId {
            await hydrate(from: liveId)
            return
        }
        existingTripId = liveId
    }

    func resumeExisting() async {
        guard let existingTripId else { return }
        await hydrate(from: existingTripId)
    }

    private func hydrate(from id: String) async {
        guard let api = model.api else { return }
        errorMessage = nil
        do {
            let data: TripDetail = try await api.get("/api/trips/\(id)")
            guard data.trip.status == "PICKUP_IN_PROGRESS" else {
                errorMessage = "That pickup is no longer in progress."
                return
            }
            tripId = data.trip.id
            existingTripId = nil
            originId = data.trip.originLocationId
            originName = data.origin?.name ?? ""
            destinationId = data.trip.destinationLocationId
            savedDestinationId = data.trip.destinationLocationId
            destinationName = data.destination?.name ?? ""
            kind = data.trip.isBareChassis ? "BARE_CHASSIS" : "CONTAINER"
            number = Marking.maskContainer(data.container?.numberNormalized ?? data.container?.number ?? "")
            containerType = data.container?.containerType
            equipmentType = data.container?.equipmentType
            chassisId = data.trip.chassisId
            chassisNumber = Marking.maskChassis(data.chassis?.number ?? "")
            sealNumber = data.trip.sealNumber ?? ""
            notes = data.trip.driverNotes ?? ""
            manualEntry = true
            selectedYardId = nil
            if let pair = data.trip.swapPairTripId {
                swapOfTripId = pair
                kind = "CONTAINER"
                isLoaded = true
                step = .confirm
            } else {
                isLoaded = data.trip.isLoaded ?? false
                step = data.trip.destinationLocationId == nil ? .destination : .confirm
            }
            reconcileStep()
        } catch {
            errorMessage = model.handle(error)
        }
    }

    private func loadSwapSite(for id: String) async {
        guard let api = model.api else { return }
        inventoryLoading = true
        defer { inventoryLoading = false }
        do {
            let site: SwapSite = try await api.get("/api/trips/\(id)/swap-site")
            originId = site.destination.id
            originName = site.destination.name ?? ""
            inventory = SiteInventory(containers: site.containers ?? [], chassis: site.chassis ?? [], csxReleases: nil)
        } catch {
            errorMessage = model.handle(error)
        }
    }

    // MARK: Answers by tapping a row

    func choose(kind chosen: String) async {
        if kind != chosen {
            containerType = nil
            equipmentType = nil
            isLoaded = nil
            selectedYardId = nil
            manualEntry = false
            inventorySearch = ""
        }
        kind = chosen
        await next()
    }

    func choose(origin location: LocationListItem) async {
        if originId != location.id {
            originId = location.id
            originName = location.name
            selectedYardId = nil
            manualEntry = false
            inventorySearch = ""
            inventory = nil
            if destinationId == location.id {
                destinationId = nil
                destinationName = ""
            }
        }
        locationSearch = ""
        if inventory == nil { await loadInventory() }
        await next()
    }

    private func loadInventory() async {
        guard let api = model.api, let originId else { return }
        inventoryLoading = true
        defer { inventoryLoading = false }
        do {
            let loaded: SiteInventory = try await api.get("/api/locations/\(originId)/inventory")
            inventory = loaded
        } catch {
            errorMessage = model.handle(error)
        }
    }

    func choose(container item: YardBox) async {
        // A row that does not say what line or size the box is cannot open a
        // trip by itself: carry its number to the typed screen to finish it.
        guard item.containerType != nil, item.equipmentType != nil, !item.isCsxRelease else {
            selectedYardId = nil
            manualEntry = true
            isLoaded = isSwap ? true : (item.isCsxRelease ? nil : item.isLoaded)
            chassisId = item.currentChassisId
            chassisNumber = Marking.maskChassis(item.chassisNumber ?? "")
            setNumber(item.numberNormalized ?? item.number)
            reconcileStep()
            await next()
            return
        }

        manualEntry = false
        selectedYardId = item.id
        resolution = nil
        number = Marking.maskContainer(item.numberNormalized ?? item.number)
        containerType = item.containerType
        equipmentType = item.equipmentType
        isLoaded = isSwap ? true : (item.isLoaded ?? false)
        sealNumber = item.sealNumber ?? ""
        chassisId = item.currentChassisId
        chassisNumber = Marking.maskChassis(item.chassisNumber ?? "")
        await next()
    }

    func choose(chassis item: YardChassis) async {
        manualEntry = false
        selectedYardId = item.id
        chassisId = item.id
        chassisNumber = Marking.maskChassis(item.number)
        await next()
    }

    /// The equipment is not on the list: type it or photograph it.
    func enterUnlisted() async {
        selectedYardId = nil
        manualEntry = true
        if isBareChassis {
            chassisId = nil
            chassisNumber = ""
        } else {
            setNumber("")
            containerType = nil
            equipmentType = nil
            isLoaded = isSwap ? true : nil
        }
        reconcileStep()
        await next()
    }

    func choose(containerType type: String) async {
        containerType = type
        await next()
    }

    func choose(equipmentType type: String) async {
        equipmentType = type
        await next()
    }

    func choose(destination location: LocationListItem) async {
        destinationId = location.id
        destinationName = location.name
        locationSearch = ""
        await next()
    }

    // MARK: Typed numbers

    func setNumber(_ text: String) {
        let masked = Marking.maskContainer(text)
        guard masked != number else {
            // The field showed a character the mask dropped: redraw it.
            if masked != text { objectWillChange.send() }
            return
        }
        number = masked
        resolution = nil
        promptedHoldFor = ""
        resolveTask?.cancel()
        if masked.count == 11 {
            resolveTask = Task { await checkPool() }
        }
        reconcileStep()
    }

    func setChassis(_ text: String) {
        let masked = Marking.maskChassis(text)
        guard masked != chassisNumber else {
            if masked != text { objectWillChange.send() }
            return
        }
        chassisNumber = masked
        chassisId = nil
    }

    /// Ask the server what it would do with this number: new record, known
    /// container, or one another driver is holding.
    private func checkPool() async {
        guard let api = model.api else { return }
        let asked = number
        resolving = true
        defer { resolving = false }
        do {
            var found: PoolResolution = try await api.get("/api/containers/resolve", query: ["number": asked])
            guard asked == number, !Task.isCancelled else { return }

            if found.outcome == "CONFLICT", let held = found.container, promptedHoldFor != held.id {
                promptedHoldFor = held.id
                let driver = found.holder?.driverName ?? "Another driver"
                let box = Marking.formatContainer(held.number ?? asked)
                let release = await ask(Question(
                    title: "Release this container?",
                    message: "\(driver) currently has \(box). Release it and add it here?",
                    confirmLabel: "Release"
                ))
                if release {
                    let _: OkResult = try await api.post("/api/containers/\(held.id)/release-driver")
                    found = try await api.get("/api/containers/resolve", query: ["number": asked])
                    guard asked == number else { return }
                }
            }

            resolution = found
            if let type = found.container?.containerType { containerType = type }
            if let type = found.container?.equipmentType { equipmentType = type }
            reconcileStep()
        } catch {
            guard asked == number else { return }
            errorMessage = model.handle(error)
        }
    }

    // MARK: Photo

    private struct ScanBody: Encodable {
        let image: String
    }

    /// Send a photo of the equipment to the server and fill in what it reads.
    /// Reading never blocks the pickup: both numbers stay editable.
    func read(photo image: UIImage) async {
        guard let api = model.api, let dataUrl = image.jpegDataUrl(maxDimension: 1600) else { return }
        photo = image
        readingPhoto = true
        photoMessage = nil
        errorMessage = nil
        defer { readingPhoto = false }
        do {
            let result: ScanResult = try await api.post("/api/scan/recognize", body: ScanBody(image: dataUrl), patient: true)
            if let container = result.container, !isBareChassis { setNumber(container) }
            if let chassis = result.chassis, !isAttach { setChassis(chassis) }
            let missing = isBareChassis ? result.chassis == nil : result.container == nil
            if missing {
                photoMessage = result.message ?? "No number could be read. Type it in, or retake the photo."
            }
        } catch {
            photoMessage = "Could not read the photo. Type the number in, or retake the photo."
            _ = model.handle(error)
        }
    }

    // MARK: Moving between steps

    func back() {
        guard canGoBack else { return }
        errorMessage = nil
        locationSearch = ""
        step = steps[stepIndex - 1]
    }

    func next() async {
        errorMessage = nil

        if !isAttach, (step == .inventory && !manualEntry) || step == .equipment {
            guard await attachChassis() else { return }
        }

        if !isAttach, step == claimStep, tripId == nil {
            await startPickup()
            guard tripId != nil else { return }
        }

        guard await saveDestination() else { return }

        let current = steps
        guard let index = current.firstIndex(of: step), index < current.count - 1 else { return }
        step = current[index + 1]
    }

    /// Keeps `step` on a step this pickup still has after an answer changed.
    private func reconcileStep() {
        let current = steps
        guard !current.contains(step) else { return }
        let following = Step.allCases.first { $0.rawValue > step.rawValue && current.contains($0) }
        let previous = Step.allCases.last { $0.rawValue < step.rawValue && current.contains($0) }
        step = following ?? previous ?? current.first ?? .kind
    }

    // MARK: Talking to the server

    private struct NumberBody: Encodable {
        let number: String
    }

    /// Look the typed chassis up (the server creates it if it is new) and
    /// ask before taking one that is under another container.
    private func attachChassis() async -> Bool {
        guard let api = model.api else { return false }
        guard !chassisNumber.isEmpty else {
            chassisId = nil
            return true
        }
        do {
            let found: ChassisLookup = try await api.post("/api/chassis", body: NumberBody(number: chassisNumber))
            let keep = fromYard ? selectedYardId : resolution?.container?.id
            if let holder = found.item.currentContainerId, holder != keep {
                let box = Marking.formatContainer(found.item.currentContainerNumber)
                let release = await ask(Question(
                    title: "Release this chassis?",
                    message: "This chassis is attached to container number \(box.isEmpty ? "another container" : box) already. Would you like to release it?",
                    confirmLabel: "Release"
                ))
                guard release else { return false }
                let _: OkResult = try await api.post("/api/chassis/\(found.item.id)/release")
            }
            chassisId = found.item.id
            chassisNumber = Marking.maskChassis(found.item.number)
            return true
        } catch {
            errorMessage = model.handle(error)
            return false
        }
    }

    private struct StartBody: Encodable {
        let eventId: String
        let kind: String
        let originLocationId: String
        let swapOfTripId: String?
        let chassisId: String?
        let containerNumber: String?
        let containerType: String?
        let equipmentType: String?
        let gps: GpsFix?
    }

    private func startPickup() async {
        guard let api = model.api, let kind, let originId else {
            errorMessage = "Choose what you are picking up and where."
            return
        }
        if isBareChassis, chassisId == nil {
            errorMessage = "Enter a chassis number."
            return
        }
        if !isBareChassis, containerType == nil || equipmentType == nil {
            errorMessage = "Choose container type and size."
            return
        }
        submitting = true
        defer { submitting = false }
        do {
            let result: TripEnvelope = try await api.post("/api/pickups/start", body: StartBody(
                eventId: UUID().uuidString.lowercased(),
                kind: kind,
                originLocationId: originId,
                swapOfTripId: swapOfTripId,
                chassisId: isBareChassis ? chassisId : nil,
                containerNumber: isBareChassis ? nil : number,
                containerType: isBareChassis ? nil : containerType,
                equipmentType: isBareChassis ? nil : equipmentType,
                gps: await LocationFix.shared.current()
            ))
            tripId = result.trip.id
        } catch {
            // The server names the trip already in progress so it can be
            // picked up again and not opened twice.
            if let apiError = error as? APIError, apiError.status == 409, let resumeId = apiError.details["tripId"] {
                existingTripId = resumeId
            }
            errorMessage = model.handle(error)
        }
    }

    private struct DestinationBody: Encodable {
        let destinationLocationId: String
    }

    /// Keep the open trip's drop-off current as soon as it is chosen.
    private func saveDestination() async -> Bool {
        guard let api = model.api, let tripId, let destinationId, savedDestinationId != destinationId else { return true }
        do {
            let _: OkResult = try await api.post("/api/trips/\(tripId)/destination", body: DestinationBody(destinationLocationId: destinationId))
            savedDestinationId = destinationId
            return true
        } catch {
            errorMessage = model.handle(error)
            return false
        }
    }

    private struct ConfirmBody: Encodable {
        let eventId: String
        let chassisId: String?
        let destinationLocationId: String?
        let isLoaded: Bool
        let sealNumber: String?
        let notes: String?
        let gps: GpsFix?
    }

    private struct AttachBody: Encodable {
        let eventId: String
        let containerNumber: String
        let containerType: String
        let equipmentType: String
        let isLoaded: Bool
        let sealNumber: String?
    }

    func confirm() async {
        guard let api = model.api, !submitting else { return }
        let loaded = isBareChassis ? false : (isSwap || isLoaded == true)
        let seal = sealNumber.trimmingCharacters(in: .whitespaces)
        if loaded && seal.isEmpty {
            errorMessage = "Enter a seal number for a loaded container."
            step = .seal
            reconcileStep()
            return
        }
        errorMessage = nil

        if let attachTripId {
            guard let containerType, let equipmentType else {
                errorMessage = "Choose container type and size."
                return
            }
            submitting = true
            defer { submitting = false }
            do {
                let _: OkResult = try await api.post("/api/trips/\(attachTripId)/attach-container", body: AttachBody(
                    eventId: UUID().uuidString.lowercased(),
                    containerNumber: number,
                    containerType: containerType,
                    equipmentType: equipmentType,
                    isLoaded: loaded,
                    sealNumber: loaded ? seal : nil
                ))
                await savePhoto(to: attachTripId)
                finished = true
            } catch {
                errorMessage = model.handle(error)
            }
            return
        }

        guard let tripId else { return }
        guard await attachChassis() else { return }
        submitting = true
        defer { submitting = false }
        let note = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let _: OkResult = try await api.post("/api/trips/\(tripId)/confirm", body: ConfirmBody(
                eventId: UUID().uuidString.lowercased(),
                chassisId: chassisId,
                destinationLocationId: destinationId,
                isLoaded: loaded,
                sealNumber: loaded ? seal : nil,
                notes: note.isEmpty ? nil : note,
                gps: await LocationFix.shared.current()
            ))
            await savePhoto(to: tripId)
            finished = true
        } catch {
            errorMessage = model.handle(error)
        }
    }

    /// File the photo taken during the pickup on the trip, so dispatch sees
    /// it on the container. A failure here does not undo the pickup.
    private func savePhoto(to tripId: String) async {
        guard let photo else { return }
        let name = "\(number.isEmpty ? chassisNumber : number)-pickup.jpg"
        _ = try? await TripFiles.upload(photo, named: name, to: .trip(tripId), api: model.api)
    }

    private struct CancelBody: Encodable {
        let eventId: String
        let reason: String
    }

    /// Give the pickup up. An open trip is cancelled so the equipment is
    /// released; nothing is left half started.
    func abandon() async {
        if let api = model.api, let tripId, !isAttach {
            submitting = true
            defer { submitting = false }
            do {
                let _: OkResult = try await api.post("/api/trips/\(tripId)/cancel", body: CancelBody(
                    eventId: UUID().uuidString.lowercased(),
                    reason: isSwap ? "Driver cancelled the swap pickup." : "Driver cancelled before confirming."
                ))
            } catch {
                errorMessage = model.handle(error)
                return
            }
        }
        finished = true
    }

    // MARK: Questions

    private func ask(_ next: Question) async -> Bool {
        await withCheckedContinuation { continuation in
            answer?.resume(returning: false)
            answer = continuation
            question = next
        }
    }

    func answerQuestion(_ yes: Bool) {
        question = nil
        answer?.resume(returning: yes)
        answer = nil
    }
}
