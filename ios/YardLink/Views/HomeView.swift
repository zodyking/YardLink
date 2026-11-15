import SwiftUI

/// Driver home: the trip in hand and today's work, as the server reports it.
struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    let user: SessionUser

    @State private var home: HomePayload?
    @State private var loading = true
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let errorMessage {
                        ErrorBanner(message: errorMessage)
                    }

                    if let home {
                        Text("Hello \(home.driver.firstName)")
                            .font(.title2.weight(.bold))
                            .foregroundColor(Brand.navy)

                        if let active = home.active {
                            TripCardView(title: home.swapPartner == nil ? "Active trip" : "Swap · first container", active: active)
                            if let partner = home.swapPartner {
                                TripCardView(title: "Swap · second container", active: partner)
                            }
                        } else {
                            Card {
                                Text("No active trip")
                                    .font(.headline)
                                    .foregroundColor(Brand.navy)
                                Text("Start a pickup to put a container on this card.")
                                    .font(.subheadline)
                                    .foregroundColor(Brand.muted)
                            }
                        }

                        let tasks = home.todayTasks ?? []
                        Card {
                            HStack {
                                Text("Today's tasks")
                                    .font(.headline)
                                    .foregroundColor(Brand.navy)
                                Spacer()
                                StatusPill(text: "\(tasks.count)", color: tasks.isEmpty ? Brand.muted : Brand.linkBlue)
                            }
                            if tasks.isEmpty {
                                Text("Nothing assigned for today yet.")
                                    .font(.subheadline)
                                    .foregroundColor(Brand.muted)
                            } else {
                                ForEach(tasks) { task in
                                    HStack(alignment: .top, spacing: 8) {
                                        Image(systemName: task.status == "DONE" ? "checkmark.circle.fill" : "circle")
                                            .foregroundColor(task.status == "DONE" ? Brand.ok : Brand.muted)
                                        Text(task.title ?? "Task")
                                            .font(.subheadline)
                                            .foregroundColor(Brand.navy)
                                    }
                                }
                            }
                        }

                        if let server = model.serverURL {
                            Card {
                                Text("Pickups, drop-offs, yard and time cards")
                                    .font(.headline)
                                    .foregroundColor(Brand.navy)
                                Text("These steps run in the Yard Link web app for now, signed in to the same server.")
                                    .font(.subheadline)
                                    .foregroundColor(Brand.muted)
                                Link(destination: server) {
                                    Label("Open Yard Link on the web", systemImage: "safari")
                                        .frame(maxWidth: .infinity, minHeight: 48)
                                }
                                .buttonStyle(SecondaryButtonStyle())
                            }
                        }
                    } else if loading {
                        ProgressView("Loading your day…")
                            .frame(maxWidth: .infinity, minHeight: 200)
                    }
                }
                .padding(16)
            }
            .background(Brand.mist.ignoresSafeArea())
            .navigationTitle("Home")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await load() }
            .task { await load() }
        }
    }

    private func load() async {
        guard let api = model.api else { return }
        do {
            let payload: HomePayload = try await api.get("/api/home")
            home = payload
            errorMessage = nil
        } catch {
            errorMessage = model.handle(error)
        }
        loading = false
    }
}

private struct TripCardView: View {
    let title: String
    let active: HomePayload.Active

    private var statusText: String {
        switch active.trip.status {
        case "PICKUP_IN_PROGRESS": return "Pickup in progress"
        case "IN_TRANSIT": return "In transit"
        case "DROPOFF_IN_PROGRESS": return "Drop-off in progress"
        case "DROPPED_OFF": return "Dropped off"
        case "COMPLETED": return "Completed"
        default: return active.trip.status.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    var body: some View {
        Card {
            HStack {
                Text(title.uppercased())
                    .font(.caption.weight(.bold))
                    .foregroundColor(Brand.muted)
                Spacer()
                StatusPill(text: statusText)
            }
            Text(active.container?.number ?? (active.trip.kind == "BARE_CHASSIS" ? "Bare chassis" : "Container"))
                .font(.system(.title3, design: .monospaced).weight(.bold))
                .foregroundColor(Brand.navy)
            if let chassis = active.chassis?.number {
                row("Chassis", chassis)
            }
            if active.trip.kind != "BARE_CHASSIS" {
                row("Cargo", (active.trip.isLoaded ?? false) ? "Loaded" : "Empty")
            }
            if let seal = active.trip.sealNumber, !seal.isEmpty {
                row("Seal", seal)
            }
            if let origin = active.origin?.name {
                row("From", origin)
            }
            if let destination = active.destination?.name {
                row("To", destination)
            }
            if let reference = active.trip.reference {
                row("Trip", reference)
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.subheadline)
                .foregroundColor(Brand.muted)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(Brand.navy)
            Spacer(minLength: 0)
        }
    }
}
