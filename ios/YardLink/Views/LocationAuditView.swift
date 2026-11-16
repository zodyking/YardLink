import SwiftUI

/// Bring a location's list in line with what is really on the ground:
/// tick off what is there, send boxes somewhere else, or take them off.
struct LocationAuditView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let locationId: String
    let locationName: String

    private enum Mode: String, CaseIterable {
        case check, move, remove

        var label: String {
            switch self {
            case .check: return "Checklist"
            case .move: return "Move"
            case .remove: return "Remove"
            }
        }

        var hint: String {
            switch self {
            case .check: return "Untick anything that is not on this yard. What stays ticked is confirmed here."
            case .move: return "Tick the containers that are really at another location, then choose where."
            case .remove: return "Tick the containers to take off this location. They go to Uncategorized."
            }
        }
    }

    @State private var mode: Mode = .check
    @State private var containers: [SiteContainer] = []
    @State private var chassis: [SiteChassis] = []
    /// Checklist: what is here. Starts with everything ticked.
    @State private var present: Set<String> = []
    /// Move and Remove: what to act on. Starts empty.
    @State private var chosen: Set<String> = []
    @State private var loading = true
    @State private var working = false
    @State private var pickingDestination = false
    @State private var confirmingRemove = false
    @State private var errorMessage: String?
    @State private var note: String?

    private var missingContainers: [String] { containers.map(\.id).filter { !present.contains($0) } }
    private var missingChassis: [String] { chassis.map(\.id).filter { !present.contains($0) } }
    private var chosenContainers: [String] { containers.map(\.id).filter { chosen.contains($0) } }

    private var actionLabel: String {
        switch mode {
        case .check:
            let count = missingContainers.count + missingChassis.count
            return count == 0 ? "Everything Is Here" : "Take \(count) Off This Location"
        case .move:
            return chosenContainers.isEmpty ? "Choose Containers" : "Move \(chosenContainers.count)…"
        case .remove:
            return chosenContainers.isEmpty ? "Choose Containers" : "Remove \(chosenContainers.count)"
        }
    }

    private var canAct: Bool {
        guard !working else { return false }
        switch mode {
        case .check: return !(missingContainers.isEmpty && missingChassis.isEmpty)
        case .move, .remove: return !chosenContainers.isEmpty
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let errorMessage { ErrorBanner(message: errorMessage) }
                if let note { Banner(kind: .success, message: note) }

                SegmentChoice(options: Mode.allCases.map { ($0, $0.label) }, selected: mode) { mode = $0 }
                Text(mode.hint).font(.footnote).foregroundColor(Brand.muted)

                if loading {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 160)
                } else {
                    SectionTitle(text: "Containers (\(containers.count))")
                    if containers.isEmpty {
                        Text("No containers are listed here.").font(.subheadline).foregroundColor(Brand.muted)
                    }
                    ForEach(containers) { box in
                        tickRow(
                            id: box.id,
                            title: Marking.formatContainer(box.number),
                            detail: [
                                Words.line(box.containerType),
                                Words.size(box.equipmentType),
                                box.isLoaded.map { $0 ? "Loaded" : "Empty" },
                            ].compactMap { $0 }.joined(separator: " · ")
                        )
                    }

                    if mode == .check && !chassis.isEmpty {
                        SectionTitle(text: "Bare chassis (\(chassis.count))")
                        ForEach(chassis) { unit in
                            tickRow(id: unit.id, title: unit.number, detail: unit.provider ?? "")
                        }
                    }
                }
            }
            .padding(16)
        }
        .screenBackground()
        .navigationTitle("Audit")
        .navigationBarTitleDisplayMode(.inline)
        .lightBar()
        .safeAreaInset(edge: .bottom) {
            BottomBar {
                Button(working ? "Saving…" : actionLabel) { act() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!canAct)
            }
        }
        .sheet(isPresented: $pickingDestination) {
            LocationPickerSheet(title: "Move To", excludeId: locationId) { location, api in
                let _: OkResult = try await api.post("/api/locations/\(locationId)/audit", body: Request(
                    action: "move",
                    containerIds: chosenContainers,
                    chassisIds: nil,
                    destinationLocationId: location.id
                ))
                note = "Moved to \(location.name)."
                await load()
            }
        }
        .confirmationDialog("Remove from \(locationName)?", isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Remove \(chosenContainers.count)", role: .destructive) {
                Task { await send(Request(action: "delete", containerIds: chosenContainers, chassisIds: nil, destinationLocationId: nil), done: "Removed from this location.") }
            }
            Button("Keep", role: .cancel) {}
        } message: {
            Text("They move to Uncategorized, where a dispatcher can place them.")
        }
        .refreshable { await load() }
        .task { await load() }
    }

    private func isTicked(_ id: String) -> Bool {
        mode == .check ? present.contains(id) : chosen.contains(id)
    }

    private func tickRow(id: String, title: String, detail: String) -> some View {
        let ticked = isTicked(id)
        return Button {
            if mode == .check {
                if ticked { present.remove(id) } else { present.insert(id) }
            } else {
                if ticked { chosen.remove(id) } else { chosen.insert(id) }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: ticked ? "checkmark.square.fill" : "square")
                    .font(.title2)
                    .foregroundColor(ticked ? Brand.linkBlue : Brand.muted)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(.body, design: .monospaced).weight(.bold))
                        .foregroundColor(Brand.navy)
                    if !detail.isEmpty {
                        Text(detail).font(.footnote).foregroundColor(Brand.muted)
                    }
                }
                Spacer(minLength: 0)
                if mode == .check && !ticked {
                    Text("NOT HERE")
                        .font(.caption2.weight(.bold))
                        .foregroundColor(Brand.warn)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            .cardSurface()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(ticked ? "ticked" : "not ticked")")
    }

    private func act() {
        switch mode {
        case .check:
            Task {
                await send(
                    Request(action: "check", containerIds: missingContainers, chassisIds: missingChassis, destinationLocationId: nil),
                    done: "Checklist saved."
                )
            }
        case .move:
            pickingDestination = true
        case .remove:
            confirmingRemove = true
        }
    }

    private struct Request: Encodable {
        let action: String
        let containerIds: [String]
        let chassisIds: [String]?
        let destinationLocationId: String?
    }

    private func load() async {
        guard let api = model.api else { return }
        do {
            let detail: LocationDetail = try await api.get("/api/locations/\(locationId)")
            containers = detail.containers ?? []
            chassis = detail.chassis ?? []
            present = Set(containers.map(\.id) + chassis.map(\.id))
            chosen = []
            errorMessage = nil
        } catch {
            errorMessage = model.handle(error)
        }
        loading = false
    }

    private func send(_ request: Request, done: String) async {
        guard let api = model.api else { return }
        working = true
        errorMessage = nil
        note = nil
        defer { working = false }
        do {
            let _: OkResult = try await api.post("/api/locations/\(locationId)/audit", body: request)
            note = done
            await load()
        } catch {
            errorMessage = model.handle(error)
        }
    }
}
