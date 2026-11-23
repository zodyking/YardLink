import SwiftUI

/// Record a trip the driver ran without the app — forgot to log it live, or
/// it happened before they started using it — with the real equipment and
/// stops entered up front. Mirrors POST /api/trips/manual, which writes the
/// trip straight to its finished state (the same pool/chassis end-state a
/// live pickup-then-drop-off would leave) and syncs the driver's time card
/// for the dates it covers, so history reads the same either way.
struct ManualTripEntrySheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    /// When opened from a trip-history gap, the gap this trip should close.
    var gap: TripGap?
    let onSaved: (String) -> Void

    @State private var kind = "CONTAINER"
    @State private var containerNumber = ""
    @State private var containerType: String?
    @State private var equipmentType: String?
    @State private var chassisNumber = ""
    @State private var isLoaded = false
    @State private var sealNumber = ""
    @State private var originId: String?
    @State private var originName: String?
    @State private var destinationId: String?
    @State private var destinationName: String?
    @State private var customer = ""
    @State private var pickedUpAt = Date()
    @State private var droppedOffAt = Date()
    @State private var notes = ""
    @State private var pickingOrigin = false
    @State private var pickingDestination = false
    @State private var saving = false
    @State private var errorMessage: String?

    /// Sizes a trip can be recorded as — the full set, since the equipment
    /// behind a backdated trip is usually already known, not guessed at the
    /// way a brand-new container is during a live pickup.
    private static let sizes: [(value: String, label: String)] = [
        ("DRY_20", "20' Dry"),
        ("DRY_40", "40' Dry"),
        ("HC_40", "40' HC"),
        ("HC_45", "45' HC"),
        ("REEFER", "Reefer"),
        ("TANK", "Tank"),
        ("OPEN_TOP", "Open top"),
        ("FLAT_RACK", "Flat rack"),
        ("OTHER", "Other"),
    ]

    private var isBareChassis: Bool { kind == "BARE_CHASSIS" }
    private var check: Marking.ContainerCheck { Marking.checkContainer(containerNumber) }
    private var chassisOk: Bool { chassisNumber.isEmpty || Marking.isCompleteChassis(chassisNumber) }

    private var canSave: Bool {
        guard originId != nil, destinationId != nil else { return false }
        guard droppedOffAt >= pickedUpAt else { return false }
        if isBareChassis { return Marking.isCompleteChassis(chassisNumber) }
        return check.structureValid && containerType != nil && equipmentType != nil && chassisOk
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let errorMessage { ErrorBanner(message: errorMessage) }
                    if let gap {
                        Banner(kind: .info, message: "This records the trip missing between \(gap.fromName) and \(gap.toName).")
                    }

                    FieldLabel(text: "What moved?")
                    SegmentChoice(
                        options: [("CONTAINER", "Container"), ("BARE_CHASSIS", "Bare chassis")],
                        selected: kind
                    ) { kind = $0 }

                    if !isBareChassis { containerFields }

                    FieldLabel(text: isBareChassis ? "Chassis number" : "Chassis number (optional)")
                    MarkingField(
                        placeholder: "AIMZ481345",
                        text: Binding(get: { chassisNumber }, set: { chassisNumber = Marking.maskChassis($0) }),
                        state: chassisNumber.isEmpty ? .idle : (chassisOk ? .ok : .problem)
                    )
                    if !chassisOk {
                        Text("A chassis number is four letters then six digits.")
                            .font(.footnote)
                            .foregroundColor(Brand.danger)
                    }

                    stopField(title: "Origin", name: originName, placeholder: "Where did it start?") { pickingOrigin = true }
                    stopField(title: "Destination", name: destinationName, placeholder: "Where did it end?") { pickingDestination = true }

                    FieldLabel(text: "Picked up")
                    FieldBox {
                        DatePicker("Picked up", selection: $pickedUpAt, displayedComponents: [.date, .hourAndMinute])
                            .labelsHidden()
                    }

                    FieldLabel(text: "Dropped off")
                    FieldBox {
                        DatePicker("Dropped off", selection: $droppedOffAt, displayedComponents: [.date, .hourAndMinute])
                            .labelsHidden()
                    }
                    if droppedOffAt < pickedUpAt {
                        Text("Drop-off should be after pickup.")
                            .font(.footnote)
                            .foregroundColor(Brand.danger)
                    }

                    FieldLabel(text: "Customer (optional)")
                    FieldBox {
                        TextField("Customer", text: $customer)
                    }

                    FieldLabel(text: "Notes (optional)")
                    FieldBox {
                        TextField("What happened", text: $notes, axis: .vertical)
                            .lineLimit(3...6)
                    }

                    Button(saving ? "Saving…" : "Save Trip") { Task { await save() } }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(saving || !canSave)
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .screenBackground()
            .navigationTitle("Record a Trip")
            .navigationBarTitleDisplayMode(.inline)
            .lightBar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .sheet(isPresented: $pickingOrigin) {
                LocationPickerSheet(title: "Origin", selectedId: originId) { location, _ in
                    originId = location.id
                    originName = location.name
                }
                .sheetChrome()
            }
            .sheet(isPresented: $pickingDestination) {
                LocationPickerSheet(title: "Destination", selectedId: destinationId, excludeId: originId) { location, _ in
                    destinationId = location.id
                    destinationName = location.name
                }
                .sheetChrome()
            }
            .onAppear(perform: prefillFromGap)
        }
    }

    @ViewBuilder
    private var containerFields: some View {
        FieldLabel(text: "Container number")
        MarkingField(
            placeholder: "MSCU4521894",
            text: Binding(get: { containerNumber }, set: { containerNumber = Marking.maskContainer($0) }),
            state: containerNumber.count >= 11 ? (check.valid ? .ok : .problem) : .idle
        )
        if containerNumber.count >= 11 {
            if let problem = check.problem {
                Text(problem).font(.footnote).foregroundColor(Brand.danger)
            }
            if let note = check.note {
                Text(note).font(.footnote).foregroundColor(Brand.warn)
            }
        } else {
            Text("Four letters and seven digits, as painted on the box.")
                .font(.footnote)
                .foregroundColor(Brand.muted)
        }

        FieldLabel(text: "Line")
        ForEach(EquipmentChoices.lines, id: \.value) { line in
            OptionRow(symbol: "shippingbox.fill", title: line.label, selected: containerType == line.value) {
                containerType = line.value
            }
        }

        FieldLabel(text: "Size")
        ForEach(Self.sizes, id: \.value) { size in
            OptionRow(symbol: "ruler.fill", title: size.label, selected: equipmentType == size.value) {
                equipmentType = size.value
            }
        }

        FieldLabel(text: "Empty or loaded?")
        SegmentChoice(options: [(false, "Empty"), (true, "Load")], selected: isLoaded) { isLoaded = $0 }

        if isLoaded {
            FieldLabel(text: "Seal number")
            FieldBox {
                TextField("Seal number", text: $sealNumber)
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
            }
        }
    }

    @ViewBuilder
    private func stopField(title: String, name: String?, placeholder: String, action: @escaping () -> Void) -> some View {
        FieldLabel(text: title)
        Button(action: action) {
            HStack {
                Text(name ?? placeholder)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(name == nil ? Brand.muted : Brand.navy)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundColor(Brand.muted.opacity(0.6))
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 50)
            .background(Brand.paper)
            .clipShape(RoundedRectangle(cornerRadius: Brand.controlRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Brand.controlRadius, style: .continuous)
                    .stroke(Brand.line, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    /// Suggests the gap's two stops as the trip's origin and destination —
    /// only when each is a real location, not just a name the trips showed.
    private func prefillFromGap() {
        guard let gap, originId == nil, destinationId == nil else { return }
        if let id = gap.fromLocationId { originId = id; originName = gap.fromName }
        if let id = gap.toLocationId { destinationId = id; destinationName = gap.toName }
    }

    private struct ManualTripPayload: Encodable {
        struct ResolvesGap: Encodable {
            let priorTripId: String
            let nextTripId: String
        }

        let kind: String
        let containerNumber: String?
        let containerType: String?
        let equipmentType: String?
        let chassisNumber: String?
        let isLoaded: Bool
        let sealNumber: String?
        let originLocationId: String
        let destinationLocationId: String
        let customer: String?
        let pickedUpAt: String
        let droppedOffAt: String
        let notes: String?
        let resolvesGap: ResolvesGap?
    }

    private struct ManualTripResult: Decodable {
        struct TripRef: Decodable { let id: String }
        let trip: TripRef
    }

    private func save() async {
        guard let api = model.api, let originId, let destinationId else { return }
        saving = true
        errorMessage = nil
        defer { saving = false }

        let trimmedChassis = chassisNumber.trimmingCharacters(in: .whitespaces)
        let trimmedSeal = sealNumber.trimmingCharacters(in: .whitespaces)
        let trimmedCustomer = customer.trimmingCharacters(in: .whitespaces)
        let trimmedNotes = notes.trimmingCharacters(in: .whitespaces)

        let payload = ManualTripPayload(
            kind: kind,
            containerNumber: isBareChassis ? nil : containerNumber,
            containerType: isBareChassis ? nil : containerType,
            equipmentType: isBareChassis ? nil : equipmentType,
            chassisNumber: trimmedChassis.isEmpty ? nil : trimmedChassis,
            isLoaded: isBareChassis ? false : isLoaded,
            sealNumber: (isBareChassis || !isLoaded || trimmedSeal.isEmpty) ? nil : trimmedSeal,
            originLocationId: originId,
            destinationLocationId: destinationId,
            customer: trimmedCustomer.isEmpty ? nil : trimmedCustomer,
            pickedUpAt: ISO8601DateFormatter().string(from: pickedUpAt),
            droppedOffAt: ISO8601DateFormatter().string(from: droppedOffAt),
            notes: trimmedNotes.isEmpty ? nil : trimmedNotes,
            resolvesGap: gap.map { ManualTripPayload.ResolvesGap(priorTripId: $0.priorTripId, nextTripId: $0.nextTripId) }
        )

        do {
            let result: ManualTripResult = try await api.post("/api/trips/manual", body: payload)
            onSaved(result.trip.id)
        } catch {
            errorMessage = model.handle(error)
        }
    }
}
