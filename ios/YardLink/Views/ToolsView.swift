import SwiftUI

/// Home's Tools menu: a short list of utilities that don't belong on the
/// main tab bar (Time Cards, Fuel Receipts, …). Bridge Crossing Times only
/// appears once a dispatcher turns it on for the company in Settings.
struct ToolsView: View {
    @Environment(\.dismiss) private var dismiss
    let bridgeCrossingTimesEnabled: Bool
    /// The container on the trip in hand, if there is one; Check CSX offers it.
    let tripContainer: TripContainer?

    struct TripContainer {
        let id: String
        let number: String
    }

    /// What Check CSX searches: everything, or one container.
    private enum CheckScope: Identifiable {
        case system
        case container(String)
        var id: String {
            switch self {
            case .system: return "system"
            case .container(let id): return id
            }
        }
    }

    @State private var choosingCheck = false
    @State private var checkScope: CheckScope?

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
            .confirmationDialog("Check CSX", isPresented: $choosingCheck, titleVisibility: .visible) {
                Button("System-wide check") { checkScope = .system }
                if let tripContainer {
                    Button("Trip container \(Marking.formatContainer(tripContainer.number))") {
                        checkScope = .container(tripContainer.id)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Check every container in the system, or only the one on your trip?")
            }
            .sheet(item: $checkScope) { scope in
                switch scope {
                case .system: ShipcsxCheckView(containerId: nil).sheetChrome()
                case .container(let id): ShipcsxCheckView(containerId: id).sheetChrome()
                }
            }
        }
    }

    private var checkCsxRow: some View {
        Button {
            // On a trip, ask which; otherwise it's the system-wide check.
            if tripContainer == nil { checkScope = .system } else { choosingCheck = true }
        } label: {
            rowLabel(
                icon: "tram.fill",
                title: "Check CSX",
                detail: tripContainer == nil
                    ? "Every container that's loaded, at a customer or at a company yard."
                    : "The whole system, or just your trip's container."
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
