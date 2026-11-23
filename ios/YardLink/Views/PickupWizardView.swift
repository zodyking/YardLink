import SwiftUI

/// The pickup, one question to a screen. Rows that answer a question move on
/// when tapped; screens that take typing keep a Continue button at the bottom.
struct PickupWizardView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var flow: PickupFlow
    private let onFinished: () -> Void

    @State private var showingCamera = false
    @State private var confirmingCancel = false

    init(mode: PickupFlow.Mode, model: AppModel, onFinished: @escaping () -> Void) {
        _flow = StateObject(wrappedValue: PickupFlow(mode: mode, model: model))
        self.onFinished = onFinished
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ProgressView(value: flow.progress)
                    .tint(Brand.linkBlue)
                    .accessibilityLabel("Step \(flow.stepIndex + 1) of \(flow.steps.count)")

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let message = flow.errorMessage {
                            ErrorBanner(message: message)
                        }
                        if flow.loading && flow.step != .kind {
                            ProgressView().frame(maxWidth: .infinity, minHeight: 120)
                        } else {
                            stepContent
                        }
                    }
                    .padding(16)
                    .animation(.easeInOut(duration: 0.2), value: flow.step)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .screenBackground()
            .navigationTitle(flow.title)
            .navigationBarTitleDisplayMode(.inline)
            .lightBar()
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if flow.canGoBack {
                        Button {
                            flow.back()
                        } label: {
                            Label("Back", systemImage: "chevron.left")
                        }
                    } else {
                        Button("Close") { close() }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { bottomBar }
            .fullScreenCover(isPresented: $showingCamera) {
                CameraCapture { image in
                    Task { await flow.read(photo: image) }
                }
                .ignoresSafeArea()
            }
            .confirmPrompt(
                flow.question?.title ?? "",
                message: flow.question?.message,
                isPresented: Binding(get: { flow.question != nil }, set: { _ in }),
                cancelLabel: "No",
                actions: [.destructive(flow.question?.confirmLabel ?? "Yes") { flow.answerQuestion(true) }],
                onCancel: { flow.answerQuestion(false) },
                dismissable: false
            )
            .confirmPrompt(
                "Cancel this pickup?",
                message: "The equipment goes back to where it was and no trip is recorded.",
                isPresented: $confirmingCancel,
                cancelLabel: "Keep Going",
                actions: [.destructive("Cancel Pickup") { Task { await flow.abandon() } }]
            )
            .task { await flow.start() }
            .onChange(of: flow.finished) { finished in
                if finished { close() }
            }
        }
    }

    /// Leaving does not cancel anything: an open pickup stays on Home as
    /// "Continue pickup".
    private func close() {
        onFinished()
        dismiss()
    }

    // MARK: Steps

    @ViewBuilder
    private var stepContent: some View {
        switch flow.step {
        case .kind: kindStep
        case .location: locationStep
        case .inventory: inventoryStep
        case .equipment: equipmentStep
        case .containerType: lineStep
        case .equipmentType: sizeStep
        case .seal: sealStep
        case .notes: notesStep
        case .destination: destinationStep
        case .confirm: confirmStep
        }
    }

    @ViewBuilder
    private var kindStep: some View {
        if flow.existingTripId != nil {
            Card {
                Banner(kind: .warning, title: "You have a pickup in progress", message: "Finish or cancel it before starting another.")
                Button("Continue That Pickup") { Task { await flow.resumeExisting() } }
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
        StepPrompt(text: "What are you picking up?")
        OptionRow(
            symbol: "shippingbox.fill",
            title: "Container",
            detail: "A box, on a chassis or to be put on one",
            selected: flow.kind == "CONTAINER"
        ) { Task { await flow.choose(kind: "CONTAINER") } }
        OptionRow(
            symbol: "box.truck.fill",
            title: "Bare chassis",
            detail: "A chassis with nothing on it",
            selected: flow.kind == "BARE_CHASSIS"
        ) { Task { await flow.choose(kind: "BARE_CHASSIS") } }
    }

    @ViewBuilder
    private var locationStep: some View {
        StepPrompt(text: "Where are you picking up?")
        SearchField(prompt: "Search locations", text: $flow.locationSearch)
        if flow.locationsLoading {
            ProgressView().frame(maxWidth: .infinity, minHeight: 100)
        } else if flow.originOptions.isEmpty {
            EmptyNote(
                title: flow.locationSearch.isEmpty ? "No locations yet" : "No locations match",
                detail: "Pick a yard, terminal or customer. Your dispatcher adds new locations."
            )
        } else {
            ForEach(flow.originOptions) { location in
                OptionRow(
                    symbol: Words.locationSymbol(location.type),
                    title: location.name,
                    detail: locationDetail(location),
                    selected: flow.originId == location.id
                ) { Task { await flow.choose(origin: location) } }
            }
        }
    }

    private func locationDetail(_ location: LocationListItem) -> String {
        var parts = [location.addressLine]
        if flow.isBareChassis {
            let count = location.availableChassis ?? 0
            parts.append(count == 1 ? "1 chassis" : "\(count) chassis")
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    @ViewBuilder
    private var inventoryStep: some View {
        StepPrompt(text: flow.originName.isEmpty ? "Pick from what is on site" : "On site at \(flow.originName)")
        SearchField(prompt: flow.isBareChassis ? "Search chassis" : "Search containers", text: $flow.inventorySearch)

        if flow.inventoryLoading {
            ProgressView("Loading equipment…").frame(maxWidth: .infinity, minHeight: 100)
        } else if flow.isBareChassis {
            ForEach(flow.yardChassis) { chassis in
                OptionRow(
                    symbol: "box.truck.fill",
                    title: chassis.number,
                    detail: [chassis.provider, chassis.sizeCompatibility].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                    selected: flow.selectedYardId == chassis.id
                ) { Task { await flow.choose(chassis: chassis) } }
            }
            if flow.yardChassis.isEmpty {
                EmptyNote(title: "No chassis listed here", detail: "Enter the number of the one you are taking.")
            }
        } else {
            ForEach(flow.yardContainers) { box in
                OptionRow(
                    symbol: box.isCsxRelease ? "list.bullet.clipboard.fill" : "shippingbox.fill",
                    title: Marking.formatContainer(box.numberNormalized ?? box.number),
                    detail: containerDetail(box),
                    trailing: box.isCsxRelease ? "CSX LIST" : nil,
                    selected: flow.selectedYardId == box.id
                ) { Task { await flow.choose(container: box) } }
            }
            if flow.yardContainers.isEmpty {
                EmptyNote(title: "No containers listed here", detail: "Enter the number of the one you are taking.")
            }
        }

        OptionRow(
            symbol: "camera.viewfinder",
            title: flow.isBareChassis ? "A different chassis" : "A different container",
            detail: "Type the number or photograph it",
            tint: Brand.navy
        ) { Task { await flow.enterUnlisted() } }
    }

    private func containerDetail(_ box: YardBox) -> String {
        var parts: [String] = []
        if let line = Words.line(box.containerType) { parts.append(line) }
        if let size = Words.size(box.equipmentType) { parts.append(size) }
        if box.isCsxRelease {
            if let pickup = box.pickupNumber, !pickup.isEmpty { parts.append("Pickup \(pickup)") }
        } else {
            parts.append((box.isLoaded ?? false) ? "Loaded" : "Empty")
            if let chassis = box.chassisNumber, !chassis.isEmpty { parts.append("On \(chassis)") }
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var equipmentStep: some View {
        Button {
            showingCamera = true
        } label: {
            Label(flow.photo == nil ? "Scan with the Camera" : "Retake Photo", systemImage: "camera.fill")
        }
        .buttonStyle(DarkButtonStyle())
        .disabled(flow.readingPhoto)

        if flow.readingPhoto {
            HStack(spacing: 10) {
                ProgressView()
                Text("Reading the photo…").font(.subheadline).foregroundColor(Brand.muted)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        } else if let message = flow.photoMessage {
            Banner(kind: .warning, message: message)
        }

        if !flow.isBareChassis {
            FieldLabel(text: "Container number")
            MarkingField(
                placeholder: "MSCU4521894",
                text: Binding(get: { flow.number }, set: { flow.setNumber($0) }),
                state: containerState
            )
            if flow.number.count >= 11 {
                if let problem = flow.check.problem {
                    Text(problem).font(.footnote).foregroundColor(Brand.danger)
                }
                if let note = flow.check.note {
                    Text(note).font(.footnote).foregroundColor(Brand.warn)
                }
            } else {
                Text("Four letters and seven digits, as painted on the box.")
                    .font(.footnote)
                    .foregroundColor(Brand.muted)
            }
            resolutionNotice
        }

        if flow.isAttach {
            Card {
                InfoRow(label: "Chassis", value: flow.chassisNumber)
                Text("The container goes on the chassis you are pulling.")
                    .font(.footnote)
                    .foregroundColor(Brand.muted)
            }
        } else {
            FieldLabel(text: flow.isBareChassis ? "Chassis number" : "Chassis number (optional)")
            MarkingField(
                placeholder: "AIMZ481345",
                text: Binding(get: { flow.chassisNumber }, set: { flow.setChassis($0) }),
                state: flow.chassisNumber.isEmpty ? .idle : (flow.chassisOk ? .ok : .problem)
            )
            if !flow.chassisNumber.isEmpty && !flow.chassisOk {
                Text("A chassis number is four letters then six digits.")
                    .font(.footnote)
                    .foregroundColor(Brand.danger)
            }
        }

        if !flow.isBareChassis && !flow.isSwap {
            FieldLabel(text: "Is it empty or loaded?")
            SegmentChoice(
                options: [(false, "Empty"), (true, "Load")],
                selected: flow.isLoaded
            ) { flow.isLoaded = $0 }
        }
    }

    private var containerState: MarkingField.Mark {
        guard flow.number.count >= 11 else { return .idle }
        return flow.check.valid ? .ok : .problem
    }

    @ViewBuilder
    private var resolutionNotice: some View {
        if flow.resolving {
            HStack(spacing: 8) {
                ProgressView()
                Text("Checking this number…").font(.footnote).foregroundColor(Brand.muted)
            }
        } else if let resolution = flow.resolution {
            switch resolution.outcome {
            case "CREATE":
                Banner(kind: .success, title: "New container record", message: resolution.message ?? "A record will be created for this container.")
            case "REACTIVATE":
                Banner(kind: .warning, title: "Known container", message: resolution.message ?? "It will be put back into service.")
            case "CONFLICT":
                Banner(kind: .error, title: "Another driver holds this container", message: resolution.message ?? "Release it to take it.")
            default:
                Banner(kind: .info, title: "Already in the active pool", message: resolution.message ?? "This container is known.")
            }
        }
    }

    @ViewBuilder
    private var lineStep: some View {
        StepPrompt(text: "Whose container is it?")
        ForEach(EquipmentChoices.lines, id: \.value) { line in
            OptionRow(
                symbol: "shippingbox.fill",
                title: line.label,
                selected: flow.containerType == line.value
            ) { Task { await flow.choose(containerType: line.value) } }
        }
    }

    @ViewBuilder
    private var sizeStep: some View {
        StepPrompt(text: "How long is it?")
        ForEach(EquipmentChoices.sizes, id: \.value) { size in
            OptionRow(
                symbol: "ruler.fill",
                title: size.label,
                selected: flow.equipmentType == size.value
            ) { Task { await flow.choose(equipmentType: size.value) } }
        }
    }

    @ViewBuilder
    private var sealStep: some View {
        StepPrompt(text: "What is the seal number?")
        FieldBox {
            TextField("Seal number", text: $flow.sealNumber)
                .font(.system(.title3, design: .monospaced))
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .submitLabel(.done)
        }
        Text("Read it off the seal on the door. A loaded container needs one.")
            .font(.footnote)
            .foregroundColor(Brand.muted)
    }

    @ViewBuilder
    private var notesStep: some View {
        StepPrompt(text: "Anything dispatch should know?")
        FieldBox {
            TextField("Notes (optional)", text: $flow.notes, axis: .vertical)
                .lineLimit(4...8)
                .padding(.vertical, 12)
        }
    }

    @ViewBuilder
    private var destinationStep: some View {
        StepPrompt(text: "Where is it going?")
        SearchField(prompt: "Search locations", text: $flow.locationSearch)
        if flow.destinationOptions.isEmpty {
            EmptyNote(title: "No locations match", detail: "Pick the yard, terminal or customer you are taking it to.")
        } else {
            ForEach(flow.destinationOptions) { location in
                OptionRow(
                    symbol: Words.locationSymbol(location.type),
                    title: location.name,
                    detail: location.addressLine,
                    selected: flow.destinationId == location.id
                ) { Task { await flow.choose(destination: location) } }
            }
        }
    }

    @ViewBuilder
    private var confirmStep: some View {
        StepPrompt(text: flow.isAttach ? "Check it, then hang the container." : "Check it, then confirm the pickup.")
        TripCard(content: TripCard.Content(
            status: nil,
            isBareChassis: flow.isBareChassis,
            containerNumber: flow.isBareChassis ? nil : flow.number,
            chassisNumber: flow.chassisNumber.isEmpty ? nil : flow.chassisNumber,
            equipmentType: flow.equipmentType,
            containerType: flow.containerType,
            isLoaded: flow.isSwap || flow.isLoaded == true,
            sealNumber: flow.sealNumber,
            originName: flow.originName.isEmpty ? nil : flow.originName,
            destinationName: flow.destinationName.isEmpty ? nil : flow.destinationName
        ))
        if !flow.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Card {
                SectionTitle(text: "Notes")
                Text(flow.notes).font(.subheadline).foregroundColor(Brand.navy)
            }
        }
        if flow.photo != nil {
            Label("The photo you took is saved with this trip.", systemImage: "photo.fill")
                .font(.footnote)
                .foregroundColor(Brand.muted)
        }
    }

    // MARK: Bottom bar

    @ViewBuilder
    private var bottomBar: some View {
        if flow.step == .confirm {
            BottomBar {
                Button(flow.submitting ? "Saving…" : (flow.isAttach ? "Hang Container" : "Confirm Pickup")) {
                    Task { await flow.confirm() }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!flow.canConfirm)

                if flow.tripId != nil && !flow.isAttach {
                    Button("Cancel Pickup") { confirmingCancel = true }
                        .buttonStyle(DangerTextButtonStyle())
                        .disabled(flow.submitting)
                }
            }
        } else if flow.showsContinue {
            BottomBar {
                Button(flow.submitting ? "Saving…" : "Continue") {
                    Task { await flow.next() }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!flow.canContinue)
            }
        }
    }
}

/// The question a step asks, above its answers.
private struct StepPrompt: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.title3.weight(.bold))
            .foregroundColor(Brand.navy)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Entry for a painted number: large monospaced capitals with a mark that
/// says whether the number is complete and correct.
struct MarkingField: View {
    enum Mark {
        case idle, ok, problem
    }

    let placeholder: String
    @Binding var text: String
    let state: Mark

    var body: some View {
        FieldBox(problem: state == .problem) {
            HStack(spacing: 8) {
                TextField(placeholder, text: $text)
                    .font(.system(.title3, design: .monospaced).weight(.semibold))
                    .foregroundColor(Brand.navy)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                switch state {
                case .ok:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(Brand.ok)
                        .accessibilityLabel("Number is valid")
                case .problem:
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundColor(Brand.danger)
                        .accessibilityLabel("Number has a problem")
                case .idle:
                    EmptyView()
                }
            }
        }
    }
}
