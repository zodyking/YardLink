import SwiftUI

/// Where equipment can be: yards, customers, terminals. Search finds a
/// location by name or address, or a container or chassis by its number.
struct LocationsView: View {
    @EnvironmentObject private var model: AppModel

    @State private var items: [LocationListItem] = []
    @State private var hits: [EquipmentHit] = []
    @State private var addingLocation = false
    @State private var query = ""
    @State private var loading = true
    @State private var errorMessage: String?
    @ObservedObject private var rootTap = TabRootTap.shared
    @State private var path = NavigationPath()

    private static let groups: [(title: String, types: [String])] = [
        ("Company yards", ["COMPANY_YARD"]),
        ("Customers", ["CUSTOMER"]),
        ("Marine terminals / Rail yards", ["MARINE_TERMINAL", "RAIL_TERMINAL"]),
    ]

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    PageHeader("Containers") {
                        Button {
                            addingLocation = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(IconButtonStyle())
                        .accessibilityLabel("Add a location")
                    }

                    SearchField(prompt: "Location, container or chassis", text: $query)

                    if let errorMessage { ErrorBanner(message: errorMessage) }

                    if !hits.isEmpty {
                        SectionTitle(text: "Equipment")
                        ForEach(hits) { hit in
                            NavigationLink(value: EquipmentRoute(kind: hit.kind, id: hit.id)) {
                                HStack(spacing: 12) {
                                    Image(systemName: hit.kind == "CHASSIS" ? "box.truck.fill" : "shippingbox.fill")
                                        .foregroundColor(Brand.linkBlue)
                                        .frame(width: 32)
                                    VStack(alignment: .leading, spacing: 2) {
                                        EquipmentNumber(
                                            text: hit.kind == "CHASSIS" ? hit.number : Marking.formatContainer(hit.number),
                                            font: .system(.body, design: .monospaced),
                                            label: hit.kind == "CHASSIS" ? "Chassis" : "Container",
                                            copyOnTap: false,
                                            kind: hit.kind == "CHASSIS" ? .chassis : .container
                                        )
                                        Text("\(hit.kind == "CHASSIS" ? "Chassis" : "Container") · \(hit.locationName ?? "No location")")
                                            .font(.footnote)
                                            .foregroundColor(Brand.muted)
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundColor(Brand.muted.opacity(0.6))
                                }
                                .padding(14)
                                .cardSurface()
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    ForEach(Self.groups, id: \.title) { group in
                        let rows = items.filter { !($0.isUncategorized ?? false) && group.types.contains($0.type ?? "") }
                        if !rows.isEmpty {
                            SectionTitle(text: group.title)
                            ForEach(rows) { item in
                                NavigationLink(value: item) { LocationRow(item: item) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }

                    let other = items.filter { $0.isUncategorized ?? false }
                    if !other.isEmpty {
                        SectionTitle(text: "Uncategorized")
                        ForEach(other) { item in
                            NavigationLink(value: item) { LocationRow(item: item) }
                                .buttonStyle(.plain)
                        }
                    }

                    if !loading && items.isEmpty && hits.isEmpty && errorMessage == nil {
                        EmptyNote(
                            title: query.isEmpty ? "No locations yet" : "No match",
                            detail: query.isEmpty ? "Your dispatcher adds locations." : "No location, container, or chassis matches that search."
                        )
                    }
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .screenBackground()
            .overlay { if loading && items.isEmpty { ProgressView() } }
            .brandScreen()
            .sheet(isPresented: $addingLocation) {
                LocationFormView { Task { await load() } }
                    .sheetChrome()
            }
            .navigationDestination(for: LocationListItem.self) { item in
                LocationDetailView(locationId: item.id, title: item.name)
            }
            .navigationDestination(for: EquipmentRoute.self) { route in
                route.destination
            }
            .refreshable { await load() }
            .task(id: query) {
                // Wait for a pause in typing before asking the server.
                if !query.isEmpty { try? await Task.sleep(nanoseconds: 350_000_000) }
                if Task.isCancelled { return }
                await load()
            }
            .onChange(of: rootTap.event) { event in
                // Tapping Containers again while already there pops back to it.
                guard event?.screen == AnyHashable(MainTabs.Screen.containers) else { return }
                path = NavigationPath()
            }
        }
    }

    private func load() async {
        guard let api = model.api else { return }
        let text = query.trimmingCharacters(in: .whitespaces)
        var parameters = ["limit": "200", "includeUncategorized": "1"]
        if !text.isEmpty { parameters["q"] = text }
        do {
            let list: LocationList = try await api.get("/api/locations", query: parameters)
            if Task.isCancelled { return }
            items = list.items
            hits = list.equipment ?? []
            errorMessage = nil
        } catch {
            if Task.isCancelled { return }
            errorMessage = model.handle(error)
        }
        loading = false
    }
}

/// A container or chassis page, reachable from search, a location, or history.
struct EquipmentRoute: Hashable {
    let kind: String
    let id: String

    @ViewBuilder var destination: some View {
        if kind == "CHASSIS" {
            ChassisDetailView(chassisId: id)
        } else {
            ContainerDetailView(containerId: id)
        }
    }
}

private struct LocationRow: View {
    let item: LocationListItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: Words.locationSymbol(item.type))
                .font(.title3)
                .foregroundColor(Brand.linkBlue)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.body.weight(.semibold))
                    .foregroundColor(Brand.navy)
                if !item.addressLine.isEmpty {
                    Text(item.addressLine)
                        .font(.footnote)
                        .foregroundColor(Brand.muted)
                        .lineLimit(1)
                }
                if let matched = item.matchedNumbers, !matched.isEmpty {
                    Text("Has \(matched.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundColor(Brand.linkBlue)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(item.occupancy ?? 0)")
                    .font(.headline)
                    .foregroundColor(Brand.navy)
                Text("on site")
                    .font(.caption2)
                    .foregroundColor(Brand.muted)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .accessibilityElement(children: .combine)
    }
}

struct LocationDetailView: View {
    @EnvironmentObject private var model: AppModel
    let locationId: String
    let title: String

    @State private var detail: LocationDetail?
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var noteText = ""
    @State private var savingNote = false
    @State private var addingEquipment = false
    @State private var editingLocation = false
    @State private var exportingList = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let errorMessage { ErrorBanner(message: errorMessage) }

                if let detail {
                    about(detail.location)

                    actions(detail.location)

                    if isCsxYard(detail.location) {
                        pickupList(detail)
                    }

                    equipment(detail)
                    notes(detail)
                } else if loading {
                    ProgressView("Loading location…").frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(16)
        }
        .screenBackground()
        .navigationTitle(detail?.location.name ?? title)
        .navigationBarTitleDisplayMode(.inline)
        .lightBar()
        .sheet(isPresented: $editingLocation) {
            if let detail {
                LocationFormView(record: detail.location) { Task { await load() } }
                    .sheetChrome()
            }
        }
        .sheet(isPresented: $addingEquipment) {
            AddEquipmentView(locationId: locationId, locationName: detail?.location.name ?? title) {
                Task { await load() }
            }
            .sheetChrome()
        }
        .sheet(isPresented: $exportingList) {
            LocationExportSheet(locationId: locationId)
                .sheetChrome()
        }
        .refreshable { await load() }
        .task { await load() }
        // Back from the pickup list, show what was added.
        .onAppear { if detail != nil { Task { await load() } } }
    }

    /// A rail yard with CSX in its name keeps a list of pickup numbers.
    private func isCsxYard(_ location: LocationRecord) -> Bool {
        location.type == "RAIL_TERMINAL" && location.name.localizedCaseInsensitiveContains("csx")
    }

    /// The location's actions as one row of even tiles, icon over a word.
    private func actions(_ location: LocationRecord) -> some View {
        HStack(spacing: 10) {
            Button { addingEquipment = true } label: {
                actionTile("Add", symbol: "plus", primary: true)
            }
            .buttonStyle(.plain)

            Button { editingLocation = true } label: {
                actionTile("Edit", symbol: "pencil")
            }
            .buttonStyle(.plain)

            Button { exportingList = true } label: {
                actionTile("Export", symbol: "square.and.arrow.up")
            }
            .buttonStyle(.plain)

            NavigationLink {
                LocationAuditView(locationId: locationId, locationName: location.name)
            } label: {
                actionTile("Audit", symbol: "checklist.checked")
            }
            .buttonStyle(.plain)
        }
    }

    private func actionTile(_ title: String, symbol: String, primary: Bool = false) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .frame(height: 22)
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundColor(primary ? .white : Brand.navy)
        .frame(maxWidth: .infinity, minHeight: 68)
        .background(primary ? Brand.linkBlue : Brand.paper)
        .clipShape(RoundedRectangle(cornerRadius: Brand.controlRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Brand.controlRadius, style: .continuous).stroke(primary ? Color.clear : Brand.line))
        .shadow(color: Brand.navy.opacity(primary ? 0.18 : 0.06), radius: 6, x: 0, y: 2)
        .contentShape(Rectangle())
    }

    private func actionLabel(_ title: String, symbol: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            Text(title).lineLimit(1)
        }
        .font(.subheadline.weight(.semibold))
    }

    @ViewBuilder
    private func pickupList(_ detail: LocationDetail) -> some View {
        let releases = detail.csxReleases ?? []
        HStack {
            SectionTitle(text: "CSX pickup list (\(releases.count))")
            Spacer()
            NavigationLink {
                CsxListView(locationId: locationId)
            } label: {
                actionLabel("Add", symbol: "plus").foregroundColor(Brand.linkBlue)
            }
        }
        Card {
            if releases.isEmpty {
                Text("No pickup numbers yet.").font(.subheadline).foregroundColor(Brand.muted)
            }
            ForEach(releases) { release in
                HStack {
                    Text(Marking.formatContainer(release.containerNumber))
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(Brand.navy)
                    Spacer()
                    Text(release.pickupNumber ?? "")
                        .font(.subheadline)
                        .foregroundColor(Brand.muted)
                }
                .frame(minHeight: 36)
            }
        }
    }

    private func hasDetails(_ location: LocationRecord) -> Bool {
        [location.hours, location.gateInstructions, location.driverNotes, location.mainPhone, location.contactPhone]
            .contains { !($0 ?? "").isEmpty }
    }

    @ViewBuilder
    private func about(_ location: LocationRecord) -> some View {
        Card {
            VStack(spacing: 10) {
                ZStack {
                    Circle().fill(Brand.skyWash).frame(width: 52, height: 52)
                    Image(systemName: Words.locationSymbol(location.type))
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(Brand.linkBlue)
                }
                Text(Words.locationType(location.type).uppercased())
                    .font(.caption2.weight(.bold))
                    .tracking(0.8)
                    .foregroundColor(Brand.linkBlue)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Brand.skyWash))
                let cityLine = [location.city, [location.state, location.postalCode].compactMap { $0 }.joined(separator: " ")]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
                let address = [location.addressLine1, cityLine].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
                if !address.isEmpty {
                    Text(address)
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(Brand.navy)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            if hasDetails(location) { Divider() }
            InfoRow(label: "Hours", value: location.hours)
            InfoRow(label: "Gate", value: location.gateInstructions)
            InfoRow(label: "Driver notes", value: location.driverNotes)
            PhoneRow(label: "Main", number: location.mainPhone)
            PhoneRow(label: location.contactName ?? "Contact", number: location.contactPhone)
        }
    }

    @ViewBuilder
    private func equipment(_ detail: LocationDetail) -> some View {
        let boxes = detail.containers ?? []
        let chassis = detail.chassis ?? []

        SectionTitle(text: "Containers on site (\(boxes.count))")
        if boxes.isEmpty {
            Card { Text("No containers here.").font(.subheadline).foregroundColor(Brand.muted) }
        } else {
            Card {
                ForEach(boxes) { box in
                    NavigationLink(value: EquipmentRoute(kind: "CONTAINER", id: box.id)) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                EquipmentNumber(text: Marking.formatContainer(box.number), font: .system(.body, design: .monospaced), label: "Container", copyOnTap: false, kind: .container)
                                Text([
                                    Words.line(box.containerType),
                                    Words.size(box.equipmentType),
                                    box.isLoaded.map { $0 ? "Loaded" : "Empty" },
                                    box.chassisNumber.map { "Chassis \($0)" },
                                ].compactMap { $0 }.joined(separator: " · "))
                                    .font(.footnote)
                                    .foregroundColor(Brand.muted)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote).foregroundColor(Brand.muted)
                        }
                        .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                }
            }
        }

        if !chassis.isEmpty {
            SectionTitle(text: "Bare chassis (\(chassis.count))")
            Card {
                ForEach(chassis) { unit in
                    NavigationLink(value: EquipmentRoute(kind: "CHASSIS", id: unit.id)) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                EquipmentNumber(text: unit.number, font: .system(.body, design: .monospaced), label: "Chassis", copyOnTap: false, kind: .chassis)
                                if let provider = unit.provider, !provider.isEmpty {
                                    Text(provider).font(.footnote).foregroundColor(Brand.muted)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote).foregroundColor(Brand.muted)
                        }
                        .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private func notes(_ detail: LocationDetail) -> some View {
        SectionTitle(text: "Notes")
        Card {
            let notes = detail.notes ?? []
            if notes.isEmpty {
                Text("No notes. Notes are removed a month after they are left.")
                    .font(.subheadline)
                    .foregroundColor(Brand.muted)
            }
            ForEach(notes) { note in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(note.body).font(.subheadline).foregroundColor(Brand.navy)
                        Text("\(note.authorName ?? "Someone") · \(Format.dateTime(note.createdAt))")
                            .font(.caption)
                            .foregroundColor(Brand.muted)
                    }
                    Spacer(minLength: 0)
                    if note.mine == true {
                        Button(role: .destructive) {
                            Task { await deleteNote(note) }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .accessibilityLabel("Delete note")
                    }
                }
            }
            Divider()
            TextField("Leave a note for the next driver", text: $noteText, axis: .vertical)
                .lineLimit(1...4)
            Button(savingNote ? "Saving…" : "Add Note") { Task { await addNote() } }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(savingNote || noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func load() async {
        guard let api = model.api else { return }
        do {
            let loaded: LocationDetail = try await api.get("/api/locations/\(locationId)")
            detail = loaded
            errorMessage = nil
        } catch {
            errorMessage = model.handle(error)
        }
        loading = false
    }

    private struct NoteBody: Encodable { let body: String }

    private func addNote() async {
        guard let api = model.api else { return }
        savingNote = true
        defer { savingNote = false }
        do {
            let _: LocationNoteEnvelope = try await api.post("/api/locations/\(locationId)/notes", body: NoteBody(body: noteText))
            noteText = ""
            await load()
        } catch {
            errorMessage = model.handle(error)
        }
    }

    private func deleteNote(_ note: LocationNote) async {
        guard let api = model.api else { return }
        do {
            let _: OkResult = try await api.delete("/api/locations/\(locationId)/notes/\(note.id)")
            await load()
        } catch {
            errorMessage = model.handle(error)
        }
    }
}
