import SwiftUI

// Forms that change equipment records: add to a location, correct a
// container, move it, correct a chassis, and a terminal's CSX pickup list.
// Each sends what was typed; the server checks it and records the change.

/// Line and size pickers shared by the forms that describe a container.
private struct ContainerDescription: View {
    @Binding var containerType: String?
    @Binding var equipmentType: String?
    @Binding var isLoaded: Bool?
    @Binding var sealNumber: String

    var body: some View {
        FieldLabel(text: "Whose container is it?")
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
            ForEach(EquipmentChoices.lines, id: \.value) { line in
                chip(line.label, on: containerType == line.value) { containerType = line.value }
            }
        }

        FieldLabel(text: "How long is it?")
        SegmentChoice(options: EquipmentChoices.sizes, selected: equipmentType) { equipmentType = $0 }

        FieldLabel(text: "Is it empty or loaded?")
        SegmentChoice(options: [(false, "Empty"), (true, "Load")], selected: isLoaded) { isLoaded = $0 }

        if isLoaded == true {
            FieldLabel(text: "Seal number")
            FieldBox {
                TextField("Seal number", text: $sealNumber)
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
            }
        }
    }

    private func chip(_ label: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 50)
                .foregroundColor(on ? .white : Brand.navy)
                .background(on ? Brand.navy : Brand.paper)
                .clipShape(RoundedRectangle(cornerRadius: Brand.controlRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Brand.controlRadius, style: .continuous).stroke(on ? Brand.navy : Brand.line))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// The frame every form sheet shares: navy bar, Close, and a save button
/// that stays at the bottom.
private struct FormSheet<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let saveLabel: String
    let saving: Bool
    let canSave: Bool
    let errorMessage: String?
    let onSave: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let errorMessage { ErrorBanner(message: errorMessage) }
                    content
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
            .safeAreaInset(edge: .bottom) {
                BottomBar {
                    Button(saving ? "Saving…" : saveLabel, action: onSave)
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(saving || !canSave)
                }
            }
        }
    }
}

// MARK: - Add equipment to a location

/// Record a container or a bare chassis that is at a location but not on
/// its list yet.
struct AddEquipmentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let locationId: String
    let locationName: String
    let onSaved: () -> Void

    @State private var kind = "CONTAINER"
    @State private var number = ""
    @State private var chassis = ""
    @State private var containerType: String?
    @State private var equipmentType: String? = "DRY_40"
    @State private var isLoaded: Bool?
    @State private var sealNumber = ""
    @State private var saving = false
    @State private var readingPhoto = false
    @State private var showingCamera = false
    @State private var errorMessage: String?
    @State private var eventId = UUID().uuidString.lowercased()

    private var isContainer: Bool { kind == "CONTAINER" }
    private var check: Marking.ContainerCheck { Marking.checkContainer(number) }
    private var chassisOk: Bool { isContainer ? (chassis.isEmpty || Marking.isCompleteChassis(chassis)) : Marking.isCompleteChassis(chassis) }
    private var canSave: Bool {
        guard chassisOk, !readingPhoto else { return false }
        guard isContainer else { return true }
        let sealOk = isLoaded == false || !sealNumber.trimmingCharacters(in: .whitespaces).isEmpty
        return check.structureValid && containerType != nil && equipmentType != nil && isLoaded != nil && sealOk
    }

    var body: some View {
        FormSheet(
            title: "Add Equipment",
            saveLabel: isContainer ? "Add Container" : "Add Chassis",
            saving: saving,
            canSave: canSave,
            errorMessage: errorMessage,
            onSave: { Task { await save() } }
        ) {
            Text("Adding to \(locationName)")
                .font(.subheadline)
                .foregroundColor(Brand.muted)

            SegmentChoice(options: [("CONTAINER", "Container"), ("CHASSIS", "Bare chassis")], selected: kind) { kind = $0 }

            Button {
                showingCamera = true
            } label: {
                Label(readingPhoto ? "Reading the photo…" : "Scan with the Camera", systemImage: "camera.fill")
            }
            .buttonStyle(DarkButtonStyle())
            .disabled(readingPhoto)

            if isContainer {
                FieldLabel(text: "Container number")
                MarkingField(
                    placeholder: "MSCU4521894",
                    text: Binding(get: { number }, set: { number = Marking.maskContainer($0) }),
                    state: number.count < 11 ? .idle : (check.valid ? .ok : .problem)
                )
                if number.count >= 11, let problem = check.problem {
                    Text(problem).font(.footnote).foregroundColor(Brand.danger)
                }
            }

            FieldLabel(text: isContainer ? "Chassis number (optional)" : "Chassis number")
            MarkingField(
                placeholder: "AIMZ481345",
                text: Binding(get: { chassis }, set: { chassis = Marking.maskChassis($0) }),
                state: chassis.isEmpty ? .idle : (Marking.isCompleteChassis(chassis) ? .ok : .problem)
            )

            if isContainer {
                ContainerDescription(
                    containerType: $containerType,
                    equipmentType: $equipmentType,
                    isLoaded: $isLoaded,
                    sealNumber: $sealNumber
                )
            }
        }
        .fullScreenCover(isPresented: $showingCamera) {
            CameraCapture { image in
                Task { await read(image) }
            }
            .ignoresSafeArea()
        }
    }

    private struct ScanPayload: Encodable {
        let image: String
    }

    private func read(_ image: UIImage) async {
        guard let api = model.api, let dataUrl = image.jpegDataUrl(maxDimension: 1600) else { return }
        readingPhoto = true
        errorMessage = nil
        defer { readingPhoto = false }
        do {
            let result: ScanResult = try await api.post("/api/scan/recognize", body: ScanPayload(image: dataUrl), patient: true)
            if isContainer, let container = result.container { number = Marking.maskContainer(container) }
            if let found = result.chassis { chassis = Marking.maskChassis(found) }
            if (isContainer && result.container == nil) || (!isContainer && result.chassis == nil) {
                errorMessage = result.message ?? "No number could be read. Type it in, or retake the photo."
            }
        } catch {
            errorMessage = model.handle(error)
        }
    }

    private struct ContainerPayload: Encodable {
        let eventId: String
        let containerNumber: String
        let containerType: String
        let equipmentType: String
        let isLoaded: Bool
        let sealNumber: String?
        let chassisNumber: String?
    }

    private struct ChassisPayload: Encodable {
        let eventId: String
        let chassisNumber: String
    }

    private func save() async {
        guard let api = model.api else { return }
        saving = true
        errorMessage = nil
        defer { saving = false }
        do {
            if isContainer {
                guard let containerType, let equipmentType, let isLoaded else { return }
                let seal = sealNumber.trimmingCharacters(in: .whitespaces)
                let _: OkResult = try await api.post("/api/locations/\(locationId)/containers", body: ContainerPayload(
                    eventId: eventId,
                    containerNumber: number,
                    containerType: containerType,
                    equipmentType: equipmentType,
                    isLoaded: isLoaded,
                    sealNumber: isLoaded && !seal.isEmpty ? seal : nil,
                    chassisNumber: chassis.isEmpty ? nil : chassis
                ))
            } else {
                let _: OkResult = try await api.post("/api/locations/\(locationId)/chassis", body: ChassisPayload(eventId: eventId, chassisNumber: chassis))
            }
            onSaved()
            dismiss()
        } catch {
            errorMessage = model.handle(error)
        }
    }
}

// MARK: - Container

/// Correct a container's record.
struct ContainerEditView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let containerId: String
    let onSaved: () -> Void

    @State private var number: String
    @State private var chassis: String
    @State private var containerType: String?
    @State private var equipmentType: String?
    @State private var isLoaded: Bool?
    @State private var sealNumber: String
    @State private var saving = false
    @State private var errorMessage: String?
    @State private var eventId = UUID().uuidString.lowercased()

    init(detail: ContainerDetail, onSaved: @escaping () -> Void) {
        containerId = detail.container.id
        self.onSaved = onSaved
        _number = State(initialValue: Marking.maskContainer(detail.container.number))
        _chassis = State(initialValue: Marking.maskChassis(detail.currentChassis?.number ?? ""))
        _containerType = State(initialValue: detail.container.containerType)
        _equipmentType = State(initialValue: detail.container.equipmentType)
        _isLoaded = State(initialValue: detail.container.isLoaded)
        _sealNumber = State(initialValue: detail.container.sealNumber ?? "")
    }

    private var check: Marking.ContainerCheck { Marking.checkContainer(number) }
    private var canSave: Bool {
        check.structureValid && (chassis.isEmpty || Marking.isCompleteChassis(chassis))
    }

    var body: some View {
        FormSheet(
            title: "Edit Container",
            saveLabel: "Save Changes",
            saving: saving,
            canSave: canSave,
            errorMessage: errorMessage,
            onSave: { Task { await save() } }
        ) {
            FieldLabel(text: "Container number")
            MarkingField(
                placeholder: "MSCU4521894",
                text: Binding(get: { number }, set: { number = Marking.maskContainer($0) }),
                state: number.count < 11 ? .idle : (check.valid ? .ok : .problem)
            )
            if number.count >= 11, let problem = check.problem {
                Text(problem).font(.footnote).foregroundColor(Brand.danger)
            }

            FieldLabel(text: "Chassis number")
            MarkingField(
                placeholder: "None",
                text: Binding(get: { chassis }, set: { chassis = Marking.maskChassis($0) }),
                state: chassis.isEmpty ? .idle : (Marking.isCompleteChassis(chassis) ? .ok : .problem)
            )
            Text("Clear the chassis number to take the container off its chassis.")
                .font(.footnote)
                .foregroundColor(Brand.muted)

            ContainerDescription(
                containerType: $containerType,
                equipmentType: $equipmentType,
                isLoaded: $isLoaded,
                sealNumber: $sealNumber
            )
        }
    }

    private struct Changes: Encodable {
        let eventId: String
        let number: String
        let containerType: String?
        let equipmentType: String?
        let chassisNumber: String
        let isLoaded: Bool?
        let sealNumber: String
    }

    private func save() async {
        guard let api = model.api else { return }
        saving = true
        errorMessage = nil
        defer { saving = false }
        do {
            let _: OkResult = try await api.patch("/api/containers/\(containerId)", body: Changes(
                eventId: eventId,
                number: number,
                containerType: containerType,
                equipmentType: equipmentType,
                chassisNumber: chassis,
                isLoaded: isLoaded,
                sealNumber: isLoaded == true ? sealNumber.trimmingCharacters(in: .whitespaces) : ""
            ))
            onSaved()
            dismiss()
        } catch {
            errorMessage = model.handle(error)
        }
    }
}

/// Record that a container is now at another location, without a trip.
struct MoveContainerView: View {
    let containerId: String
    let currentLocationId: String?
    let onMoved: () -> Void

    @State private var eventId = UUID().uuidString.lowercased()

    private struct Move: Encodable {
        let eventId: String
        let destinationLocationId: String
    }

    var body: some View {
        LocationPickerSheet(
            title: "Move Container",
            hint: "Use this when the container is already somewhere else and no trip recorded it.",
            excludeId: currentLocationId
        ) { location, api in
            let _: OkResult = try await api.post("/api/containers/\(containerId)/move", body: Move(eventId: eventId, destinationLocationId: location.id))
            onMoved()
        }
    }
}

// MARK: - Chassis

/// Correct a chassis record, or take it out of service.
struct ChassisEditView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let chassisId: String
    let onSaved: () -> Void

    @State private var number: String
    @State private var provider: String
    @State private var size: String
    @State private var plate: String
    @State private var notes: String
    @State private var outOfService: Bool
    @State private var saving = false
    @State private var errorMessage: String?

    init(chassis: ChassisRecord, onSaved: @escaping () -> Void) {
        chassisId = chassis.id
        self.onSaved = onSaved
        _number = State(initialValue: Marking.maskChassis(chassis.number))
        _provider = State(initialValue: chassis.provider ?? "")
        _size = State(initialValue: chassis.sizeCompatibility ?? "")
        _plate = State(initialValue: chassis.licensePlate ?? "")
        _notes = State(initialValue: chassis.notes ?? "")
        _outOfService = State(initialValue: chassis.outOfService ?? false)
    }

    var body: some View {
        FormSheet(
            title: "Edit Chassis",
            saveLabel: "Save Changes",
            saving: saving,
            canSave: Marking.isCompleteChassis(number),
            errorMessage: errorMessage,
            onSave: { Task { await save() } }
        ) {
            FieldLabel(text: "Chassis number")
            MarkingField(
                placeholder: "AIMZ481345",
                text: Binding(get: { number }, set: { number = Marking.maskChassis($0) }),
                state: Marking.isCompleteChassis(number) ? .ok : .problem
            )
            FieldLabel(text: "Provider")
            FieldBox { TextField("For example TRAC or DCLI", text: $provider).autocorrectionDisabled() }
            FieldLabel(text: "Fits")
            FieldBox { TextField("For example 40ft", text: $size).autocorrectionDisabled() }
            FieldLabel(text: "License plate")
            FieldBox {
                TextField("Plate", text: $plate)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
            }
            FieldLabel(text: "Notes")
            FieldBox {
                TextField("Anything the next driver should know", text: $notes, axis: .vertical)
                    .lineLimit(2...5)
                    .padding(.vertical, 10)
            }
            Toggle(isOn: $outOfService) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Out of service").font(.body.weight(.semibold)).foregroundColor(Brand.navy)
                    Text("It cannot be put on a trip until this is turned off.").font(.footnote).foregroundColor(Brand.muted)
                }
            }
            .tint(Brand.linkBlue)
            .padding(14)
            .cardSurface(radius: Brand.controlRadius)
        }
    }

    private struct Changes: Encodable {
        let number: String
        let provider: String
        let sizeCompatibility: String
        let licensePlate: String
        let notes: String
        let outOfService: Bool
    }

    private func save() async {
        guard let api = model.api else { return }
        saving = true
        errorMessage = nil
        defer { saving = false }
        do {
            let _: OkResult = try await api.patch("/api/chassis/\(chassisId)", body: Changes(
                number: number,
                provider: provider.trimmingCharacters(in: .whitespaces),
                sizeCompatibility: size.trimmingCharacters(in: .whitespaces),
                licensePlate: plate.trimmingCharacters(in: .whitespaces),
                notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
                outOfService: outOfService
            ))
            onSaved()
            dismiss()
        } catch {
            errorMessage = model.handle(error)
        }
    }
}

// MARK: - CSX pickup list

/// The containers a rail terminal has released for pickup, with the pickup
/// number the gate asks for. A pickup started from this list claims its line.
struct CsxListView: View {
    @EnvironmentObject private var model: AppModel
    let locationId: String

    @State private var releases: [CsxRelease] = []
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var container = ""
    @State private var pickupNumber = ""
    @State private var saving = false

    private var canAdd: Bool {
        Marking.checkContainer(container).structureValid && !pickupNumber.trimmingCharacters(in: .whitespaces).isEmpty && !saving
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let errorMessage { ErrorBanner(message: errorMessage) }

                SectionTitle(text: "Add to the list")
                Card {
                    FieldLabel(text: "Container number")
                    MarkingField(
                        placeholder: "MSCU4521894",
                        text: Binding(get: { container }, set: { container = Marking.maskContainer($0) }),
                        state: container.count < 11 ? .idle : (Marking.checkContainer(container).valid ? .ok : .problem)
                    )
                    FieldLabel(text: "Pickup number")
                    FieldBox {
                        TextField("From the release", text: $pickupNumber)
                            .font(.system(.body, design: .monospaced))
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                    }
                    Button(saving ? "Adding…" : "Add to List") { Task { await add() } }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(!canAdd)
                }

                SectionTitle(text: "Waiting for pickup (\(releases.count))")
                if loading {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 100)
                } else if releases.isEmpty {
                    Text("Nothing is on the list.")
                        .font(.subheadline)
                        .foregroundColor(Brand.muted)
                } else {
                    ForEach(releases) { release in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                EquipmentNumber(text: Marking.formatContainer(release.containerNumber), font: .system(.body, design: .monospaced))
                                Text("Pickup \(release.pickupNumber ?? "—")")
                                    .font(.footnote)
                                    .foregroundColor(Brand.muted)
                            }
                            Spacer(minLength: 0)
                            Button(role: .destructive) {
                                Task { await remove(release) }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .frame(minWidth: 44, minHeight: 44)
                            .accessibilityLabel("Remove \(release.containerNumber) from the list")
                        }
                        .padding(14)
                        .cardSurface()
                    }
                }
            }
            .padding(16)
        }
        .scrollDismissesKeyboard(.interactively)
        .screenBackground()
        .navigationTitle("CSX Pickup List")
        .navigationBarTitleDisplayMode(.inline)
        .lightBar()
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        guard let api = model.api else { return }
        do {
            let list: CsxReleaseList = try await api.get("/api/locations/\(locationId)/csx-releases")
            releases = list.releases
            errorMessage = nil
        } catch {
            errorMessage = model.handle(error)
        }
        loading = false
    }

    private struct NewRows: Encodable {
        struct Row: Encodable {
            let containerNumber: String
            let pickupNumber: String
        }

        let source: String
        let rows: [Row]
    }

    private func add() async {
        guard let api = model.api else { return }
        saving = true
        errorMessage = nil
        defer { saving = false }
        do {
            let _: OkResult = try await api.post("/api/locations/\(locationId)/csx-releases", body: NewRows(
                source: "MANUAL",
                rows: [NewRows.Row(containerNumber: container, pickupNumber: pickupNumber.trimmingCharacters(in: .whitespaces))]
            ))
            container = ""
            pickupNumber = ""
            await load()
        } catch {
            errorMessage = model.handle(error)
        }
    }

    private func remove(_ release: CsxRelease) async {
        guard let api = model.api else { return }
        do {
            let _: OkResult = try await api.delete("/api/locations/\(locationId)/csx-releases/\(release.id)")
            await load()
        } catch {
            errorMessage = model.handle(error)
        }
    }
}
