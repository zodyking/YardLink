import SwiftUI

/// A container: where it is now, and its history one duty cycle at a time.
/// A duty cycle runs from leaving a marine terminal or rail yard until the
/// container is returned to one. The server files every event under its cycle.
struct ContainerDetailView: View {
    @EnvironmentObject private var model: AppModel
    let containerId: String

    @State private var detail: ContainerDetail?
    @State private var selectedCycleId: String?
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var sheet: ContainerSheet?
    @State private var confirmingDelete = false
    @State private var working = false
    @Environment(\.dismiss) private var dismiss

    private enum ContainerSheet: String, Identifiable {
        case edit, move, photos, shipcsx

        var id: String { rawValue }
    }

    private var cycles: [DutyCycle] { detail?.history?.cycles ?? [] }
    private var selectedCycle: DutyCycle? {
        cycles.first(where: { $0.id == selectedCycleId }) ?? cycles.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let errorMessage { ErrorBanner(message: errorMessage) }

                if let detail {
                    now(detail)
                    cycleSection
                    let unfiled = detail.history?.unfiled ?? []
                    if !unfiled.isEmpty {
                        SectionTitle(text: "Before the first pickup")
                        Card {
                            ForEach(unfiled) { event in
                                row(event)
                            }
                        }
                    }
                    SectionTitle(text: "ShipCSX")
                    Card {
                        HStack {
                            Text(detail.shipcsx?.statusLabel ?? "Not checked")
                                .font(.body.weight(.semibold))
                                .foregroundColor(Brand.navy)
                            Spacer()
                            if let checkedAt = detail.shipcsx?.checkedAt {
                                Text(Format.dateTime(checkedAt))
                                    .font(.caption)
                                    .foregroundColor(Brand.muted)
                            }
                        }
                        if let line = detail.shipcsx?.detailLine, !line.isEmpty {
                            Text(line).font(.footnote).foregroundColor(Brand.muted)
                        }
                        if detail.shipcsxCheck?.running == true {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text(detail.shipcsxCheck?.progressLine ?? "Checking…")
                                    .font(.footnote)
                                    .foregroundColor(Brand.muted)
                            }
                        }
                        Button(detail.shipcsx == nil ? "Check CSX" : "Check Again") { sheet = .shipcsx }
                            .buttonStyle(SecondaryButtonStyle())
                            .disabled(detail.shipcsxCheck?.running == true)
                    }

                    SectionTitle(text: "This container")
                    HStack(spacing: 12) {
                        Button {
                            sheet = .photos
                        } label: {
                            Label("Photos", systemImage: "photo.fill")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        Button {
                            sheet = .edit
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                    Button {
                        sheet = .move
                    } label: {
                        Label("Move to Another Location", systemImage: "arrow.right.circle.fill")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    Button(working ? "Deleting…" : "Delete Container") { confirmingDelete = true }
                        .buttonStyle(DangerTextButtonStyle())
                        .disabled(working)
                } else if loading {
                    ProgressView("Loading container…").frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(16)
        }
        .screenBackground()
        .navigationTitle(Marking.formatContainer(detail?.container.number))
        .navigationBarTitleDisplayMode(.inline)
        .lightBar()
        .sheet(item: $sheet) { sheet in
            if let detail {
                switch sheet {
                case .edit:
                    ContainerEditView(detail: detail) { Task { await load() } }
                case .move:
                    MoveContainerView(containerId: containerId, currentLocationId: detail.currentLocation?.id) { Task { await load() } }
                case .photos:
                    DocumentsSheet(scope: .container(containerId), equipmentNumber: detail.container.number)
                case .shipcsx:
                    ShipcsxCheckView(
                        containerId: containerId,
                        containerNumber: detail.container.number,
                        suggestedTerminal: detail.suggestedTerminal
                    ) { Task { await load() } }
                }
            }
        }
        .confirmationDialog("Delete this container?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Container", role: .destructive) { Task { await deleteContainer() } }
            Button("Keep", role: .cancel) {}
        } message: {
            Text("The container is removed from the lists. Its history is kept.")
        }
        .refreshable { await load() }
        .task { await load() }
    }

    @ViewBuilder
    private func now(_ detail: ContainerDetail) -> some View {
        Card {
            HStack {
                EquipmentNumber(text: detail.container.number, label: "Container", kind: .container)
                Spacer()
                if let status = Words.containerStatus(detail.container.containerStatus) {
                    StatusPill(text: status)
                }
            }
            InfoRow(label: "Line", value: Words.line(detail.container.containerType))
            InfoRow(label: "Size", value: Words.size(detail.container.equipmentType))
            InfoRow(label: "Cargo", value: detail.container.isLoaded.map { $0 ? "Loaded" : "Empty" })
            InfoRow(label: "Seal", value: detail.container.sealNumber)
            InfoRow(label: "Location", value: detail.currentLocation?.name)
            InfoRow(label: "Driver", value: detail.currentDriver?.name)
            InfoRow(label: "Chassis", value: detail.currentChassis?.number)
        }
    }

    @ViewBuilder
    private var cycleSection: some View {
        if cycles.isEmpty {
            SectionTitle(text: "Duty cycles")
            Card {
                Text("No duty cycle yet. One starts when this container is first picked up.")
                    .font(.subheadline)
                    .foregroundColor(Brand.muted)
            }
        } else if let cycle = selectedCycle {
            HStack {
                SectionTitle(text: "Duty cycle")
                if cycles.count > 1 {
                    Menu {
                        ForEach(cycles) { option in
                            Button("Cycle \(option.sequence) · \(option.statusLabel) · \(Format.dateTime(option.startedAt))") {
                                selectedCycleId = option.id
                            }
                        }
                    } label: {
                        Label("Cycle \(cycle.sequence) of \(cycles.count)", systemImage: "chevron.up.chevron.down")
                            .font(.subheadline.weight(.semibold))
                    }
                }
            }
            Card {
                HStack {
                    Text("Cycle \(cycle.sequence)")
                        .font(.headline)
                        .foregroundColor(Brand.navy)
                    Spacer()
                    StatusPill(text: cycle.statusLabel, color: cycle.status == "ACTIVE" ? Brand.linkBlue : (cycle.status == "COMPLETED" ? Brand.ok : Brand.muted))
                }
                InfoRow(label: "Started", value: Format.dateTime(cycle.startedAt))
                InfoRow(label: "From", value: cycle.startLocation?.name)
                InfoRow(label: "Returned", value: cycle.completedAt.map { Format.dateTime($0) })
                InfoRow(label: "To", value: cycle.endLocation?.name)
                InfoRow(label: "Drivers", value: (cycle.drivers ?? []).joined(separator: ", "))
                InfoRow(label: "Chassis", value: (cycle.chassis ?? []).compactMap(\.number).joined(separator: ", "))
                if cycle.closedByNextPickup == true {
                    Text("No return was recorded. This cycle was closed when the container was next collected from a terminal.")
                        .font(.footnote)
                        .foregroundColor(Brand.muted)
                }
            }
            let events = cycle.events ?? []
            if !events.isEmpty {
                Card {
                    ForEach(events) { event in
                        row(event)
                    }
                }
            }
        }
    }

    private func row(_ event: HistoryEvent) -> some View {
        TimelineRow(
            symbol: Words.eventSymbol(event.eventType),
            title: Words.event(event.eventType),
            lines: event.detailLines(showContainer: false, showChassis: true),
            date: event.occurredAt
        )
    }

    private func load() async {
        guard let api = model.api else { return }
        do {
            let loaded: ContainerDetail = try await api.get("/api/containers/\(containerId)")
            detail = loaded
            errorMessage = nil
        } catch {
            errorMessage = model.handle(error)
        }
        loading = false
    }

    private func deleteContainer() async {
        guard let api = model.api else { return }
        working = true
        defer { working = false }
        do {
            let _: OkResult = try await api.delete("/api/containers/\(containerId)")
            dismiss()
        } catch {
            errorMessage = model.handle(error)
        }
    }
}

/// A chassis: one continuous history, and every container it has carried.
struct ChassisDetailView: View {
    @EnvironmentObject private var model: AppModel
    let chassisId: String

    @State private var detail: ChassisDetail?
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var editing = false
    @State private var confirmingRelease = false
    @State private var confirmingDelete = false
    @State private var working = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let errorMessage { ErrorBanner(message: errorMessage) }

                if let detail {
                    Card {
                        HStack {
                            EquipmentNumber(text: detail.chassis.number, label: "Chassis", kind: .chassis)
                            Spacer()
                            if let status = detail.chassis.status {
                                StatusPill(text: status.replacingOccurrences(of: "_", with: " ").capitalized)
                            }
                        }
                        InfoRow(label: "Provider", value: detail.chassis.provider)
                        InfoRow(label: "Location", value: detail.currentLocation?.name)
                        InfoRow(label: "Carrying", value: detail.currentContainer?.number)
                        InfoRow(label: "Last handled", value: detail.history?.events.first(where: { $0.driverName != nil })?.driverName)
                    }

                    let pairings = detail.history?.pairings ?? []
                    SectionTitle(text: "Containers carried (\(pairings.count))")
                    if pairings.isEmpty {
                        Card { Text("This chassis has not carried a container yet.").font(.subheadline).foregroundColor(Brand.muted) }
                    } else {
                        Card {
                            ForEach(pairings) { pairing in
                                pairingRow(pairing)
                            }
                        }
                    }

                    let events = detail.history?.events ?? []
                    if !events.isEmpty {
                        SectionTitle(text: "Full history")
                        Card {
                            ForEach(events) { event in
                                TimelineRow(
                                    symbol: Words.eventSymbol(event.eventType),
                                    title: Words.event(event.eventType),
                                    lines: event.detailLines(showContainer: true, showChassis: false),
                                    date: event.occurredAt
                                )
                            }
                        }
                    }

                    SectionTitle(text: "This chassis")
                    Button {
                        editing = true
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    if detail.currentContainer?.id != nil {
                        Button {
                            confirmingRelease = true
                        } label: {
                            Label("Release from Its Container", systemImage: "minus.circle")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(working)
                    }
                    Button(working ? "Working…" : "Delete Chassis") { confirmingDelete = true }
                        .buttonStyle(DangerTextButtonStyle())
                        .disabled(working)
                } else if loading {
                    ProgressView("Loading chassis…").frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(16)
        }
        .screenBackground()
        .navigationTitle(detail?.chassis.number ?? "Chassis")
        .navigationBarTitleDisplayMode(.inline)
        .lightBar()
        .sheet(isPresented: $editing) {
            if let detail {
                ChassisEditView(chassis: detail.chassis) { Task { await load() } }
            }
        }
        .confirmationDialog("Release this chassis?", isPresented: $confirmingRelease, titleVisibility: .visible) {
            Button("Release", role: .destructive) { Task { await act(release: true) } }
            Button("Keep", role: .cancel) {}
        } message: {
            Text("The container comes off this chassis and the chassis becomes available.")
        }
        .confirmationDialog("Delete this chassis?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Chassis", role: .destructive) { Task { await act(release: false) } }
            Button("Keep", role: .cancel) {}
        } message: {
            Text("The chassis is removed from the lists. Its history is kept.")
        }
        .refreshable { await load() }
        .task { await load() }
    }

    @ViewBuilder
    private func pairingRow(_ pairing: ChassisPairing) -> some View {
        let content = VStack(alignment: .leading, spacing: 2) {
            HStack {
                EquipmentNumber(text: pairing.containerNumber ?? "Container", font: .system(.body, design: .monospaced), label: "Container", copyOnTap: false, kind: .container)
                if let sequence = pairing.dutyCycleSequence {
                    StatusPill(text: "Cycle \(sequence)", color: pairing.dutyCycleStatus == "ACTIVE" ? Brand.linkBlue : Brand.muted)
                }
                Spacer()
                if pairing.containerId != nil {
                    Image(systemName: "chevron.right").font(.footnote).foregroundColor(Brand.muted)
                }
            }
            Text("Paired \(Format.dateTime(pairing.pairedAt))\(place(pairing.pairedLocationName))\(by(pairing.pairedByDriverName))")
                .font(.footnote)
                .foregroundColor(Brand.muted)
            Text(pairing.separatedAt == nil
                 ? "Still paired"
                 : "Separated \(Format.dateTime(pairing.separatedAt))\(place(pairing.separatedLocationName))\(by(pairing.separatedByDriverName))")
                .font(.footnote)
                .foregroundColor(Brand.muted)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)

        if let containerId = pairing.containerId {
            NavigationLink(value: EquipmentRoute(kind: "CONTAINER", id: containerId)) { content }
                .buttonStyle(.plain)
        } else {
            content
        }
    }

    private func place(_ name: String?) -> String {
        guard let name, !name.isEmpty else { return "" }
        return " at \(name)"
    }

    private func by(_ name: String?) -> String {
        guard let name, !name.isEmpty else { return "" }
        return " by \(name)"
    }

    private func load() async {
        guard let api = model.api else { return }
        do {
            let loaded: ChassisDetail = try await api.get("/api/chassis/\(chassisId)")
            detail = loaded
            errorMessage = nil
        } catch {
            errorMessage = model.handle(error)
        }
        loading = false
    }

    /// Release the chassis from its container, or delete it.
    private func act(release: Bool) async {
        guard let api = model.api else { return }
        working = true
        defer { working = false }
        do {
            if release {
                let _: OkResult = try await api.post("/api/chassis/\(chassisId)/release")
                await load()
            } else {
                let _: OkResult = try await api.delete("/api/chassis/\(chassisId)")
                dismiss()
            }
        } catch {
            errorMessage = model.handle(error)
        }
    }
}
