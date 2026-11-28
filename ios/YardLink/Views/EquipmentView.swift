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
                    hero(detail)
                    facts(detail)
                    actions
                    shipcsx(detail)
                    cycleSection
                    let unfiled = (detail.history?.unfiled ?? []).filter(\.isShownInHistory)
                    if !unfiled.isEmpty {
                        SectionTitle(text: "Before the first pickup")
                        Card {
                            ForEach(unfiled) { event in
                                row(event)
                            }
                        }
                    }
                    Button(working ? "Deleting…" : "Delete Container") { confirmingDelete = true }
                        .buttonStyle(DangerTextButtonStyle())
                        .disabled(working)
                        .padding(.top, 8)
                } else if loading {
                    ProgressView("Loading container…").frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(16)
        }
        .screenBackground()
        .navigationTitle("Container")
        .navigationBarTitleDisplayMode(.inline)
        .lightBar()
        .sheet(item: $sheet) { sheet in
            Group {
                if let detail {
                    switch sheet {
                    case .edit:
                        ContainerEditView(detail: detail) { Task { await load() } }
                    case .move:
                        MoveContainerView(containerId: containerId, currentLocationId: detail.currentLocation?.id) { Task { await load() } }
                    case .photos:
                        DocumentsSheet(scope: .container(containerId), containerNumber: detail.container.number, chassisNumber: nil)
                    case .shipcsx:
                        ShipcsxCheckView(containerId: containerId) {
                            Task { await load() }
                        }
                    }
                }
            }
            .sheetChrome()
        }
        .confirmPrompt(
            "Delete this container?",
            message: "The container is removed from the lists. Its history is kept.",
            isPresented: $confirmingDelete,
            cancelLabel: "Keep",
            actions: [.destructive("Delete Container") { Task { await deleteContainer() } }]
        )
        .refreshable { await load() }
        .task { await load() }
    }

    private func hero(_ detail: ContainerDetail) -> some View {
        let box = detail.container
        return EquipmentHero(
            kind: .container,
            number: box.number,
            status: Words.containerStatus(box.containerStatus),
            tags: [
                Words.line(box.containerType),
                Words.size(box.equipmentType),
                box.isLoaded.map { $0 ? "Loaded" : "Empty" },
            ].compactMap { $0 }.filter { !$0.isEmpty }
        )
    }

    private func facts(_ detail: ContainerDetail) -> some View {
        FactGrid(facts: [
            .init(label: "Location", value: detail.currentLocation?.name),
            .init(
                label: "Chassis",
                value: detail.currentChassis?.number,
                route: detail.currentChassis?.id.map { EquipmentRoute(kind: "CHASSIS", id: $0) }
            ),
            .init(label: "Seal", value: detail.container.sealNumber),
            .init(label: "Driver", value: detail.currentDriver?.name),
        ])
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button { sheet = .shipcsx } label: {
                ActionTile(title: "Check CSX", symbol: "magnifyingglass", primary: true)
            }
            .buttonStyle(.plain)
            Button { sheet = .move } label: {
                ActionTile(title: "Move", symbol: "arrow.right.circle")
            }
            .buttonStyle(.plain)
            Button { sheet = .photos } label: {
                ActionTile(title: "Photos", symbol: "photo")
            }
            .buttonStyle(.plain)
            Button { sheet = .edit } label: {
                ActionTile(title: "Edit", symbol: "pencil")
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func shipcsx(_ detail: ContainerDetail) -> some View {
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
            if let snapshot = detail.shipcsx {
                ForEach(snapshot.rows, id: \.label) { row in
                    InfoRow(label: row.label, value: row.value)
                }
            }
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
                SectionTitle(text: "History")
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
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Cycle \(cycle.sequence)")
                            .font(.headline)
                            .foregroundColor(Brand.navy)
                        Text(cycleLine(cycle))
                            .font(.footnote)
                            .foregroundColor(Brand.muted)
                    }
                    Spacer()
                    StatusPill(text: cycle.statusLabel, color: cycle.status == "ACTIVE" ? Brand.linkBlue : (cycle.status == "COMPLETED" ? Brand.ok : Brand.muted))
                }
                InfoRow(label: "Drivers", value: (cycle.drivers ?? []).joined(separator: ", "))
                InfoRow(label: "Chassis", value: (cycle.chassis ?? []).compactMap(\.number).joined(separator: ", "))
                if cycle.closedByNextPickup == true {
                    Text("No return was recorded. This cycle was closed when the container was next collected from a terminal.")
                        .font(.footnote)
                        .foregroundColor(Brand.muted)
                }
                let events = (cycle.events ?? []).filter(\.isShownInHistory)
                if !events.isEmpty {
                    Divider()
                    ForEach(events) { event in
                        row(event)
                    }
                }
            }
        }
    }

    /// Where the cycle started and, once returned, where it ended.
    private func cycleLine(_ cycle: DutyCycle) -> String {
        let start = ["From \(cycle.startLocation?.name ?? "unknown")", Format.dateTime(cycle.startedAt)].joined(separator: " · ")
        guard let completedAt = cycle.completedAt else { return start }
        return start + "\nReturned to \(cycle.endLocation?.name ?? "unknown") · \(Format.dateTime(completedAt))"
    }

    private func row(_ event: HistoryEvent) -> some View {
        TimelineRow(
            symbol: Words.eventSymbol(event.eventType),
            title: Words.event(event),
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
                    EquipmentHero(
                        kind: .chassis,
                        number: detail.chassis.number,
                        status: detail.chassis.status.map { $0.replacingOccurrences(of: "_", with: " ").capitalized },
                        tags: [detail.chassis.provider, detail.chassis.sizeCompatibility].compactMap { $0 }.filter { !$0.isEmpty }
                    )
                    FactGrid(facts: [
                        .init(label: "Location", value: detail.currentLocation?.name),
                        .init(
                            label: "Carrying",
                            value: detail.currentContainer?.number.map { Marking.formatContainer($0) },
                            route: detail.currentContainer?.id.map { EquipmentRoute(kind: "CONTAINER", id: $0) }
                        ),
                        .init(label: "Plate", value: detail.chassis.licensePlate),
                        .init(label: "Last handled", value: detail.history?.events.first(where: { $0.driverName != nil })?.driverName),
                    ])
                    HStack(spacing: 10) {
                        Button { editing = true } label: {
                            ActionTile(title: "Edit", symbol: "pencil", primary: true)
                        }
                        .buttonStyle(.plain)
                        if detail.currentContainer?.id != nil {
                            Button { confirmingRelease = true } label: {
                                ActionTile(title: "Release Container", symbol: "minus.circle")
                            }
                            .buttonStyle(.plain)
                            .disabled(working)
                        }
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

                    let events = (detail.history?.events ?? []).filter(\.isShownInHistory)
                    if !events.isEmpty {
                        SectionTitle(text: "History")
                        Card {
                            ForEach(events) { event in
                                TimelineRow(
                                    symbol: Words.eventSymbol(event.eventType),
                                    title: Words.event(event),
                                    lines: event.detailLines(showContainer: true, showChassis: false),
                                    date: event.occurredAt
                                )
                            }
                        }
                    }

                    Button(working ? "Working…" : "Delete Chassis") { confirmingDelete = true }
                        .buttonStyle(DangerTextButtonStyle())
                        .disabled(working)
                        .padding(.top, 8)
                } else if loading {
                    ProgressView("Loading chassis…").frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(16)
        }
        .screenBackground()
        .navigationTitle("Chassis")
        .navigationBarTitleDisplayMode(.inline)
        .lightBar()
        .sheet(isPresented: $editing) {
            if let detail {
                ChassisEditView(chassis: detail.chassis) { Task { await load() } }
                    .sheetChrome()
            }
        }
        .confirmPrompt(
            "Release this chassis?",
            message: "The container comes off this chassis and the chassis becomes available.",
            isPresented: $confirmingRelease,
            cancelLabel: "Keep",
            actions: [.destructive("Release") { Task { await act(release: true) } }]
        )
        .confirmPrompt(
            "Delete this chassis?",
            message: "The chassis is removed from the lists. Its history is kept.",
            isPresented: $confirmingDelete,
            cancelLabel: "Keep",
            actions: [.destructive("Delete Chassis") { Task { await act(release: false) } }]
        )
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
