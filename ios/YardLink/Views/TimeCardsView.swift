import QuickLook
import SwiftUI

/// The driver's daily time cards, newest first. The server builds each card
/// from the day's trips and the phone's position; the driver corrects it here.
struct TimeCardsView: View {
    @EnvironmentObject private var model: AppModel

    @State private var cards: [TimeCardListItem] = []
    @State private var loading = true
    @State private var errorMessage: String?

    private var today: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if let errorMessage { ErrorBanner(message: errorMessage) }

                NavigationLink {
                    TimeCardView(workDate: today)
                } label: {
                    row(title: "Today", detail: "Open today's card", symbol: "sun.max.fill")
                }
                .buttonStyle(.plain)

                let earlier = cards.filter { $0.workDate != today }
                if !earlier.isEmpty {
                    SectionTitle(text: "Earlier days")
                    ForEach(earlier) { card in
                        NavigationLink {
                            TimeCardView(workDate: card.workDate)
                        } label: {
                            row(
                                title: Format.day(iso: card.workDate),
                                detail: summary(card),
                                symbol: card.status == "COMPLETED" ? "checkmark.seal.fill" : "clock.fill"
                            )
                        }
                        .buttonStyle(.plain)
                    }
                } else if !loading && errorMessage == nil {
                    Text("Earlier days appear here once you have worked them.")
                        .font(.footnote)
                        .foregroundColor(Brand.muted)
                }
            }
            .padding(16)
        }
        .screenBackground()
        .navigationTitle("Time Cards")
        .navigationBarTitleDisplayMode(.inline)
        .navyBar()
        .refreshable { await load() }
        .task { await load() }
    }

    private func summary(_ card: TimeCardListItem) -> String {
        let stops = card.stopCount ?? 0
        var parts = [stops == 1 ? "1 stop" : "\(stops) stops"]
        if let hours = card.totalOnDutyHours, !hours.isEmpty { parts.append("\(hours) hours on duty") }
        return parts.joined(separator: " · ")
    }

    private func row(title: String, detail: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundColor(Brand.linkBlue)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold)).foregroundColor(Brand.navy)
                Text(detail).font(.footnote).foregroundColor(Brand.muted)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundColor(Brand.muted.opacity(0.6))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .accessibilityElement(children: .combine)
    }

    private func load() async {
        guard let api = model.api else { return }
        do {
            let list: TimeCardList = try await api.get("/api/time-cards")
            cards = list.items
            errorMessage = nil
        } catch {
            errorMessage = model.handle(error)
        }
        loading = false
    }
}

/// One day's card: the header, the stops, and the finished PDF.
struct TimeCardView: View {
    @EnvironmentObject private var model: AppModel
    let workDate: String

    @State private var header = TimeCardHeader()
    @State private var stops: [TimeCardStop] = []
    @State private var loaded = false
    @State private var saving = false
    @State private var openingPdf = false
    @State private var savedNote: String?
    @State private var errorMessage: String?
    @State private var pdf: URL?

    /// The paper form has this many lines.
    private let stopLimit = 25

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let errorMessage { ErrorBanner(message: errorMessage) }
                if let savedNote { Banner(kind: .success, message: savedNote) }

                if loaded {
                    totals
                    SectionTitle(text: "Driver and truck")
                    Card {
                        field("Driver", text: binding(\.driverName))
                        field("Employee ID", text: binding(\.employeeId))
                        field("Truck unit", text: binding(\.truckUnit))
                        field("Trailer or chassis", text: binding(\.trailerNumber))
                        field("CDL", text: binding(\.cdl))
                        field("Dispatcher", text: binding(\.dispatcher))
                        field("Route or customer", text: binding(\.routeCustomer))
                        HStack(spacing: 12) {
                            field("Start odometer", text: binding(\.startOdometer), numeric: true)
                            field("End odometer", text: binding(\.endOdometer), numeric: true)
                        }
                    }

                    SectionTitle(text: "Stops")
                    if stops.isEmpty {
                        Text("No stops yet. They are added as you pick up and drop off, or you can add one.")
                            .font(.footnote)
                            .foregroundColor(Brand.muted)
                    }
                    ForEach($stops) { $stop in
                        StopEditor(stop: $stop) {
                            stops.removeAll { $0.key == stop.key }
                        }
                    }
                    Button {
                        addStop()
                    } label: {
                        Label("Add a Stop", systemImage: "plus")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(stops.count >= stopLimit)
                } else if errorMessage == nil {
                    ProgressView("Loading the card…").frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(16)
        }
        .scrollDismissesKeyboard(.interactively)
        .screenBackground()
        .navigationTitle(Format.day(iso: workDate))
        .navigationBarTitleDisplayMode(.inline)
        .navyBar()
        .safeAreaInset(edge: .bottom) {
            if loaded {
                BottomBar {
                    HStack(spacing: 12) {
                        Button(openingPdf ? "Opening…" : "View PDF") { Task { await openPdf() } }
                            .buttonStyle(SecondaryButtonStyle())
                            .disabled(openingPdf || saving)
                        Button(saving ? "Saving…" : "Save") { Task { await save() } }
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(saving)
                    }
                }
            }
        }
        .quickLookPreview($pdf)
        .task { await load() }
    }

    private var totals: some View {
        HStack(spacing: 8) {
            FactCell(label: "On duty", value: header.reportForDuty?.isEmpty == false ? (header.reportForDuty ?? "") : "—", mono: true)
            FactCell(label: "Released", value: header.releasedFromDuty?.isEmpty == false ? (header.releasedFromDuty ?? "") : "—", mono: true)
            FactCell(label: "Hours", value: header.totalOnDutyHours?.isEmpty == false ? (header.totalOnDutyHours ?? "") : "—", mono: true, alignment: .trailing)
        }
        .padding(16)
        .cardSurface()
    }

    private func binding(_ keyPath: WritableKeyPath<TimeCardHeader, String?>) -> Binding<String> {
        Binding(
            get: { header[keyPath: keyPath] ?? "" },
            set: { header[keyPath: keyPath] = $0 }
        )
    }

    private func field(_ label: String, text: Binding<String>, numeric: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption.weight(.semibold)).foregroundColor(Brand.muted)
            TextField(label, text: text)
                .font(.body)
                .foregroundColor(Brand.navy)
                .keyboardType(numeric ? .numberPad : .default)
                .autocorrectionDisabled()
                .frame(minHeight: 36)
            Divider()
        }
    }

    private func addStop() {
        let key = "MANUAL:\(Int(Date().timeIntervalSince1970)):\(UUID().uuidString.prefix(6).lowercased())"
        stops.append(TimeCardStop(key: key, timeIn: "", timeOut: "", location: "", activity: "", source: "MANUAL", tripId: nil, locationId: nil, corrected: true))
    }

    private func show(_ card: TimeCard) {
        header = card.header
        stops = card.stops
        loaded = true
    }

    private func load() async {
        guard let api = model.api, !loaded else { return }
        do {
            let result: TimeCardEnvelope = try await api.get("/api/time-cards/\(workDate)")
            show(result.card)
            errorMessage = nil
        } catch {
            errorMessage = model.handle(error)
        }
    }

    private struct Changes: Encodable {
        let header: TimeCardHeader
        let stops: [TimeCardStop]
    }

    @discardableResult
    private func save() async -> Bool {
        guard let api = model.api else { return false }
        saving = true
        errorMessage = nil
        savedNote = nil
        defer { saving = false }
        do {
            let result: TimeCardEnvelope = try await api.patch("/api/time-cards/\(workDate)", body: Changes(header: header, stops: stops))
            show(result.card)
            savedNote = "Saved."
            return true
        } catch {
            errorMessage = model.handle(error)
            return false
        }
    }

    /// The PDF is built from what is saved, so save first.
    private func openPdf() async {
        guard let api = model.api, await save() else { return }
        openingPdf = true
        defer { openingPdf = false }
        do {
            let data = try await api.data("/api/time-cards/\(workDate)/pdf")
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("time-card-\(workDate).pdf")
            try data.write(to: url, options: .atomic)
            pdf = url
        } catch {
            errorMessage = model.handle(error)
        }
    }
}

/// One stop, edited in place. Times are 24-hour, as on the paper card.
private struct StopEditor: View {
    @Binding var stop: TimeCardStop
    let onRemove: () -> Void

    private var sourceLabel: String {
        switch stop.source {
        case "TRIP": return "From a trip"
        case "GPS": return "From your position"
        default: return "Added by you"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(sourceLabel.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.7)
                    .foregroundColor(Brand.muted)
                Spacer()
                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "trash")
                }
                .frame(minWidth: 44, minHeight: 32)
                .accessibilityLabel("Remove this stop")
            }
            HStack(spacing: 12) {
                timeField("In", text: $stop.timeIn)
                timeField("Out", text: $stop.timeOut)
            }
            FieldBox {
                TextField("Location", text: $stop.location)
            }
            FieldBox {
                TextField("What you did there", text: $stop.activity)
            }
        }
        .padding(14)
        .cardSurface()
    }

    private func timeField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption.weight(.semibold)).foregroundColor(Brand.muted)
            FieldBox {
                TextField("00:00", text: text)
                    .font(.system(.body, design: .monospaced))
                    .keyboardType(.numbersAndPunctuation)
            }
        }
    }
}
