import SwiftUI

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
