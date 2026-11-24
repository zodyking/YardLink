import SwiftUI

/// Check a container on ShipCSX. The server drives the public lookup, so this
/// screen picks the CSX facility, starts the check and follows its steps.
struct ShipcsxCheckView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let containerId: String
    let containerNumber: String
    let suggestedTerminal: String?
    let onFinished: () -> Void

    @State private var terminal: String
    @State private var reference = ""
    @State private var check: ShipcsxCheck?
    @State private var starting = false
    @State private var errorMessage: String?

    init(containerId: String, containerNumber: String, suggestedTerminal: String?, onFinished: @escaping () -> Void) {
        self.containerId = containerId
        self.containerNumber = containerNumber
        self.suggestedTerminal = suggestedTerminal
        self.onFinished = onFinished
        let suggestion = suggestedTerminal?.trimmingCharacters(in: .whitespaces) ?? ""
        _terminal = State(initialValue: shipcsxTerminals.contains(suggestion) ? suggestion : shipcsxTerminals[0])
    }

    private var running: Bool { check?.running ?? false }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let errorMessage { ErrorBanner(message: errorMessage) }

                    Card {
                        InfoRow(label: "Container", value: Marking.formatContainer(containerNumber))
                    }

                    if running, let check {
                        Card {
                            SectionTitle(text: "Checking ShipCSX")
                            ProgressView(value: Double(check.stepIndex ?? 0), total: Double(max(check.stepCount ?? 1, 1)))
                                .tint(Brand.linkBlue)
                            Text(check.progressLine)
                                .font(.subheadline)
                                .foregroundColor(Brand.muted)
                            Text("This takes up to two minutes. You can leave this screen; the check carries on.")
                                .font(.footnote)
                                .foregroundColor(Brand.muted)
                        }
                    } else if check?.status == "error" {
                        Banner(kind: .error, title: "The check did not finish", message: check?.error ?? "ShipCSX could not be read.")
                    } else if check?.status == "done" {
                        Banner(kind: .success, message: "Done. The container page shows what ShipCSX said.")
                    }

                    FieldLabel(text: "Which CSX location?")
                    ForEach(shipcsxTerminals, id: \.self) { name in
                        OptionRow(
                            symbol: "tram.fill",
                            title: name,
                            detail: name == suggestedTerminal ? "Used last time" : nil,
                            selected: terminal == name
                        ) { terminal = name }
                        .disabled(running)
                    }

                    FieldLabel(text: "Reference (optional)")
                    FieldBox {
                        TextField("Leave empty to use 0000", text: $reference)
                            .font(.system(.body, design: .monospaced))
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                    }
                    .disabled(running)
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .screenBackground()
            .navigationTitle("Check CSX")
            .navigationBarTitleDisplayMode(.inline)
            .lightBar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                BottomBar {
                    Button(buttonLabel) { Task { await start() } }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(starting || running)
                }
            }
            .task { await follow() }
        }
    }

    private var buttonLabel: String {
        if running { return "Checking…" }
        if starting { return "Starting…" }
        return check?.status == "done" ? "Check Again" : "Check ShipCSX"
    }

    private struct Request: Encodable {
        let terminal: String
        let equipmentNumber: String
        let reference: String?
    }

    private func start() async {
        guard let api = model.api else { return }
        starting = true
        errorMessage = nil
        defer { starting = false }
        let trimmed = reference.trimmingCharacters(in: .whitespaces)
        do {
            let result: ShipcsxCheckEnvelope = try await api.post("/api/containers/\(containerId)/shipcsx", body: Request(
                terminal: terminal,
                equipmentNumber: containerNumber,
                reference: trimmed.isEmpty ? nil : trimmed
            ))
            check = result.check
            await follow()
        } catch {
            errorMessage = model.handle(error)
        }
    }

    /// Ask the server where the check has got to until it stops running. A
    /// server that stops answering, or forgets the check (a restart), ends
    /// the wait with a message instead of leaving the step frozen on screen.
    private func follow() async {
        guard let api = model.api else { return }
        var misses = 0
        while !Task.isCancelled, check?.running ?? false {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            do {
                let latest: ShipcsxCheckEnvelope = try await api.get("/api/containers/\(containerId)/shipcsx")
                misses = 0
                guard let next = latest.check else {
                    check = nil
                    errorMessage = "The check stopped before it finished. Try again."
                    return
                }
                check = next
            } catch {
                misses += 1
                if misses >= 5 {
                    check = nil
                    errorMessage = model.handle(error)
                    return
                }
            }
        }
        if check?.status == "done" || check?.status == "error" { onFinished() }
    }
}

/// Clear the company's records, one kind at a time. A dispatcher's tool for
/// a yard that is starting over; it cannot be undone.
struct ClearRecordsView: View {
    @EnvironmentObject private var model: AppModel

    @State private var counts: ResetCounts?
    @State private var loading = true
    @State private var clearing: String?
    @State private var confirming: (id: String, label: String, count: Int)?
    @State private var errorMessage: String?
    @State private var note: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let errorMessage { ErrorBanner(message: errorMessage) }
                if let note { Banner(kind: .success, message: note) }

                Banner(
                    kind: .warning,
                    title: "This cannot be undone",
                    message: "Clearing a kind of record deletes it for the whole company. Export anything you want to keep first."
                )

                if loading {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 160)
                } else if let counts {
                    ForEach(resetTargets, id: \.id) { target in
                        let count = counts.count(target.id)
                        Card {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(target.label).font(.body.weight(.semibold)).foregroundColor(Brand.navy)
                                    Text(target.hint).font(.footnote).foregroundColor(Brand.muted)
                                }
                                Spacer(minLength: 8)
                                Text("\(count)")
                                    .font(.system(.title3, design: .rounded).weight(.bold))
                                    .foregroundColor(count == 0 ? Brand.muted : Brand.navy)
                            }
                            Button(clearing == target.id ? "Clearing…" : "Clear \(target.label)") {
                                confirming = (target.id, target.label, count)
                            }
                            .buttonStyle(SecondaryButtonStyle())
                            .disabled(count == 0 || clearing != nil)
                        }
                    }
                }
            }
            .padding(16)
        }
        .screenBackground()
        .navigationTitle("Clear Records")
        .navigationBarTitleDisplayMode(.inline)
        .lightBar()
        .confirmPrompt(
            confirming.map { "Clear \($0.label.lowercased())?" } ?? "",
            message: confirming.map { "\($0.count) \($0.label.lowercased()) will be deleted for everyone at your company. This cannot be undone." },
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            cancelLabel: "Keep",
            actions: [.destructive(confirming.map { "Delete \($0.count)" } ?? "Delete") {
                if let target = confirming { Task { await clear(target.id, target.label) } }
            }]
        )
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        guard let api = model.api else { return }
        do {
            counts = try await api.get("/api/reset")
            errorMessage = nil
        } catch {
            errorMessage = model.handle(error)
        }
        loading = false
    }

    private struct Request: Encodable {
        let target: String
    }

    private func clear(_ id: String, _ label: String) async {
        guard let api = model.api else { return }
        confirming = nil
        clearing = id
        errorMessage = nil
        note = nil
        defer { clearing = nil }
        do {
            let _: OkResult = try await api.post("/api/reset", body: Request(target: id))
            note = "\(label) cleared."
            await load()
        } catch {
            errorMessage = model.handle(error)
        }
    }
}
