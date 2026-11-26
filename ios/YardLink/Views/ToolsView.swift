import SwiftUI

/// Home's Tools menu: a short list of utilities that don't belong on the
/// main tab bar (Time Cards, Fuel Receipts, …). Bridge Crossing Times only
/// appears once a dispatcher turns it on for the company in Settings.
struct ToolsView: View {
    @Environment(\.dismiss) private var dismiss
    let bridgeCrossingTimesEnabled: Bool
    /// The container on the trip in hand, if there is one; Check CSX puts it first.
    let tripContainer: TripContainer?

    struct TripContainer {
        let id: String
        let number: String
    }

    @State private var checking = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    row(
                        icon: "clock.badge.checkmark.fill",
                        title: "Time Cards",
                        detail: "Your stops for each day, ready to send."
                    ) {
                        TimeCardsView()
                    }

                    checkCsxRow

                    row(
                        icon: "fuelpump.fill",
                        title: "Fuel Receipts",
                        detail: "Log and review your fuel purchases."
                    ) {
                        FuelReceiptsView()
                    }

                    if bridgeCrossingTimesEnabled {
                        row(
                            icon: "road.lanes",
                            title: "Bridge Crossing Times",
                            detail: "Live NY/NJ crossing times, and whether they're trending better or worse."
                        ) {
                            BridgeCrossingsListView()
                        }
                    }
                }
                .padding(16)
            }
            .screenBackground()
            .navigationTitle("Tools")
            .navigationBarTitleDisplayMode(.inline)
            .lightBar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .sheet(isPresented: $checking) {
                ShipcsxCheckView(firstContainerId: tripContainer?.id)
                    .sheetChrome()
            }
        }
    }

    private var checkCsxRow: some View {
        Button {
            checking = true
        } label: {
            rowLabel(
                icon: "tram.fill",
                title: "Check CSX",
                detail: tripContainer.map { "\(Marking.formatContainer($0.number)), every loaded container and every one at a customer." }
                    ?? "Every loaded container and every one at a customer."
            )
        }
        .buttonStyle(.plain)
    }

    private func row<Destination: View>(
        icon: String,
        title: String,
        detail: String,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            rowLabel(icon: icon, title: title, detail: detail)
        }
        .buttonStyle(.plain)
    }

    private func rowLabel(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(Brand.linkBlue)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold)).foregroundColor(Brand.navy)
                Text(detail).font(.footnote).foregroundColor(Brand.muted)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundColor(Brand.muted.opacity(0.6))
        }
        .padding(14)
        .cardSurface()
    }
}
