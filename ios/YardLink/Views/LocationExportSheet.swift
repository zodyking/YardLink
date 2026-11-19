import SwiftUI

/// "Export list" for a location — containers, bare chassis and (optionally)
/// yard notes as plain text, ready to drop into a message. Generated on the
/// server by the same formatter the web app's console uses, so the text is
/// identical to what a dispatcher would get there.
struct LocationExportSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let locationId: String

    @State private var text = ""
    @State private var noteCount = 0
    @State private var includeNotes = false
    @State private var loading = true
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Share this location's containers, bare chassis and notes as a list.")
                        .font(.subheadline)
                        .foregroundColor(Brand.muted)

                    if let errorMessage { ErrorBanner(message: errorMessage) }

                    if noteCount > 0 {
                        Card {
                            Toggle(isOn: Binding(
                                get: { includeNotes },
                                set: { on in
                                    includeNotes = on
                                    Task { await load() }
                                }
                            )) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Include notes").font(.subheadline).foregroundColor(Brand.navy)
                                    Text("\(noteCount) on this yard").font(.caption).foregroundColor(Brand.muted)
                                }
                            }
                            .tint(Brand.linkBlue)
                            .disabled(loading)
                        }
                    }

                    Group {
                        if loading && text.isEmpty {
                            ProgressView().frame(maxWidth: .infinity, minHeight: 120)
                        } else {
                            Text(text.isEmpty ? "Nothing here to export yet." : text)
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundColor(Brand.navy)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(12)
                    .cardSurface()

                    ShareLink(item: text) {
                        Label("Share List", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(text.isEmpty || loading)
                }
                .padding(16)
            }
            .screenBackground()
            .navigationTitle("Export List")
            .navigationBarTitleDisplayMode(.inline)
            .lightBar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard let api = model.api else { return }
        loading = true
        do {
            let result: LocationExportResult = try await api.get(
                "/api/locations/\(locationId)/export",
                query: ["includeNotes": includeNotes ? "1" : "0"]
            )
            text = result.text
            noteCount = result.noteCount
            errorMessage = nil
        } catch {
            errorMessage = model.handle(error)
        }
        loading = false
    }
}
