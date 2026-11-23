import SwiftUI
import Charts

/// Live Hudson River crossing times from the Port Authority, grouped by
/// crossing with New York– and New Jersey–bound side by side. The George
/// Washington Bridge's lower level is never shown — "the GWB" here always
/// means its upper level, its only facility with a level split.
struct BridgeCrossingsListView: View {
    @EnvironmentObject private var model: AppModel

    @State private var lanes: [BridgeCrossingLane] = []
    @State private var lastUpdated: Date?
    @State private var loading = true
    @State private var errorMessage: String?

    /// Consecutive lanes for the same crossing, in the order the server sent
    /// them (already sorted by crossing, then direction).
    private var grouped: [(facilityId: Int, name: String, lanes: [BridgeCrossingLane])] {
        var result: [(facilityId: Int, name: String, lanes: [BridgeCrossingLane])] = []
        for lane in lanes {
            if let last = result.indices.last, result[last].facilityId == lane.facilityId {
                result[last].lanes.append(lane)
            } else {
                result.append((facilityId: lane.facilityId, name: lane.crossingName, lanes: [lane]))
            }
        }
        return result
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let errorMessage { ErrorBanner(message: errorMessage) }
                if let lastUpdated { LastUpdatedLabel(date: lastUpdated) }

                if loading && lanes.isEmpty {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 160)
                } else if lanes.isEmpty {
                    EmptyNote(
                        title: "No readings yet",
                        detail: "Crossing times appear here once the server has checked in with the Port Authority."
                    )
                } else {
                    ForEach(grouped, id: \.facilityId) { group in
                        crossingCard(name: group.name, lanes: group.lanes)
                    }
                }
            }
            .padding(16)
        }
        .screenBackground()
        .navigationTitle("Bridge Crossing Times")
        .navigationBarTitleDisplayMode(.inline)
        .lightBar()
        .task { await load() }
        // Keeps the page current on its own while it's open, quietly, in the
        // background — no spinner, no error banner if a tick happens to miss.
        .task { await silentRefreshLoop() }
        .refreshable { await load() }
    }

    /// Reloads on a timer for as long as this view is on screen. SwiftUI
    /// cancels `.task` automatically on disappear, which stops this loop too.
    private func silentRefreshLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            if Task.isCancelled { return }
            await load(silent: true)
        }
    }

    private func crossingCard(name: String, lanes: [BridgeCrossingLane]) -> some View {
        Card {
            // The whole card is one tap target into a single page for this
            // crossing with both directions on it — not a separate page per
            // lane, so there's one chevron for the card, not one per row.
            if let facilityId = lanes.first?.facilityId {
                NavigationLink {
                    BridgeCrossingDetailView(facilityId: facilityId, crossingName: name)
                } label: {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 10) {
                            CrossingIcon()
                            Text(name).font(.body.weight(.bold)).foregroundColor(Brand.navy)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundColor(Brand.muted.opacity(0.5))
                        }
                        ForEach(Array(lanes.enumerated()), id: \.element.id) { index, lane in
                            if index > 0 {
                                Rectangle().fill(Brand.line).frame(height: 1)
                            } else {
                                Rectangle().fill(Color.clear).frame(height: 4)
                            }
                            laneRow(lane)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func laneAccentColor(_ lane: BridgeCrossingLane) -> Color {
        if lane.isClosed { return Brand.danger }
        switch lane.trend {
        case .improving: return Brand.ok
        case .worsening: return Brand.danger
        case .steady: return Brand.line
        }
    }

    private func laneRow(_ lane: BridgeCrossingLane) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(laneAccentColor(lane))
                .frame(width: 4, height: 30)

            Text(lane.direction == .towardNY ? "To NY" : "To NJ")
                .font(.caption.weight(.bold))
                .foregroundColor(Brand.muted)
                .frame(width: 44, alignment: .leading)

            if lane.isClosed {
                Text("Closed")
                    .font(.subheadline.weight(.bold))
                    .foregroundColor(Brand.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("\(lane.travelTimeMinutes)").font(.title3.weight(.bold)).foregroundColor(Brand.navy)
                    Text("min").font(.caption).foregroundColor(Brand.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            TrendBadge(trend: lane.trend)
        }
        .padding(.vertical, 10)
    }

    /// `silent` is for the background refresh loop and skips the spinner and
    /// the error banner — a quiet tick that misses just tries again in 60s,
    /// leaving whatever's already on screen exactly as it was.
    private func load(silent: Bool = false) async {
        guard let api = model.api else { return }
        if !silent { loading = true }
        do {
            let list: BridgeCrossingLaneList = try await api.get("/api/bridge-crossings")
            lanes = list.lanes
            lastUpdated = list.lastUpdated
            errorMessage = nil
        } catch {
            if !silent { errorMessage = model.handle(error) }
        }
        loading = false
    }
}

/// "Updated 3 min ago" — ticks on its own via SwiftUI's relative date style,
/// so it stays accurate between refreshes without any extra state or timer.
private struct LastUpdatedLabel: View {
    let date: Date

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "clock.arrow.circlepath")
            Text("Updated ") + Text(date, style: .relative) + Text(" ago")
        }
        .font(.caption)
        .foregroundColor(Brand.muted)
    }
}

/// "Improving / worsening / steady" pill, shared by the list and detail
/// screens — a tinted capsule in the same spirit as Theme's `StatusPill`.
private struct TrendBadge: View {
    let trend: BridgeCrossingTrend

    private var style: (icon: String, color: Color, label: String) {
        switch trend {
        case .improving: return ("arrow.down.right", Brand.ok, "Improving")
        case .worsening: return ("arrow.up.right", Brand.danger, "Worsening")
        case .steady: return ("arrow.right", Brand.muted, "Steady")
        }
    }

    var body: some View {
        Label(style.label, systemImage: style.icon)
            .font(.caption2.weight(.bold))
            .labelStyle(.titleAndIcon)
            .foregroundColor(style.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(style.color.opacity(0.12))
            .clipShape(Capsule())
    }
}

/// The small tinted icon square used to anchor a crossing's identity, in the
/// same spirit as Theme's `OptionRow` icon chip.
private struct CrossingIcon: View {
    var body: some View {
        Image(systemName: "road.lanes")
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(Brand.linkBlue)
            .frame(width: 34, height: 34)
            .background(Brand.linkBlue.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// One crossing's last 24 hours, both directions on the same page — this
/// used to be two separate pages (one per direction) reached from two
/// separate rows; now the whole crossing is one destination, like the list
/// card above it that links here once instead of once per lane.
struct BridgeCrossingDetailView: View {
    @EnvironmentObject private var model: AppModel
    let facilityId: Int
    let crossingName: String

    @State private var toNY: BridgeCrossingDetail?
    @State private var toNJ: BridgeCrossingDetail?
    @State private var loading = true
    @State private var errorMessage: String?

    private var lastUpdated: Date? {
        [toNY?.lastUpdated, toNJ?.lastUpdated].compactMap { $0 }.max()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let errorMessage { ErrorBanner(message: errorMessage) }
                if let lastUpdated { LastUpdatedLabel(date: lastUpdated) }

                if let toNY {
                    directionSection(toNY)
                }
                if let toNJ {
                    directionSection(toNJ)
                }

                if toNY == nil && toNJ == nil {
                    if loading {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                    } else {
                        EmptyNote(
                            title: "No readings yet",
                            detail: "Crossing times appear here once the server has checked in with the Port Authority."
                        )
                    }
                }
            }
            .padding(16)
        }
        .screenBackground()
        .navigationTitle(crossingName)
        .navigationBarTitleDisplayMode(.inline)
        .lightBar()
        .task { await load() }
        .task { await silentRefreshLoop() }
        .refreshable { await load() }
    }

    private func directionSection(_ detail: BridgeCrossingDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            header(detail.lane)
            if detail.history.count > 1 {
                graph(detail.history)
            } else {
                EmptyNote(
                    title: "Not enough history yet",
                    detail: "Check back in a bit — the graph fills in as readings come in."
                )
            }
        }
    }

    private func silentRefreshLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            if Task.isCancelled { return }
            await load(silent: true)
        }
    }

    private func header(_ lane: BridgeCrossingLane) -> some View {
        Card {
            HStack(spacing: 10) {
                CrossingIcon()
                Text(lane.direction == .towardNY ? "Toward New York" : "Toward New Jersey")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Brand.muted)
                Spacer(minLength: 0)
                TrendBadge(trend: lane.trend)
            }

            if lane.isClosed {
                Text("Closed")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundColor(Brand.danger)
                    .padding(.vertical, 4)
            } else {
                HStack(alignment: .lastTextBaseline, spacing: 20) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\(lane.travelTimeMinutes)")
                                .font(.system(size: 48, weight: .bold))
                                .foregroundColor(Brand.navy)
                            Text("min").font(.title3).foregroundColor(Brand.muted)
                        }
                        Text("Right now").font(.caption).foregroundColor(Brand.muted)
                    }

                    if let typical = lane.typicalTimeMinutes {
                        Rectangle().fill(Brand.line).frame(width: 1, height: 40)
                        VStack(alignment: .leading, spacing: 0) {
                            Text("\(typical)").font(.title2.weight(.semibold)).foregroundColor(Brand.muted)
                            Text("Typically").font(.caption).foregroundColor(Brand.muted)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func graph(_ history: [BridgeCrossingHistoryPoint]) -> some View {
        let hasTypical = history.contains { $0.typicalTimeMinutes != nil }
        return Card {
            HStack {
                Text("Past 24 hours").font(.footnote.weight(.semibold)).foregroundColor(Brand.muted)
                Spacer(minLength: 8)
                legendDot(color: Brand.linkBlue, label: "This crossing")
                if hasTypical {
                    legendDot(color: Brand.muted, label: "Typical")
                }
            }
            Chart(history) { point in
                AreaMark(x: .value("Time", point.recordedAt), y: .value("Minutes", point.travelTimeMinutes))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Brand.linkBlue.opacity(0.22), Brand.linkBlue.opacity(0)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", point.recordedAt), y: .value("Minutes", point.travelTimeMinutes))
                    .foregroundStyle(Brand.linkBlue)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.monotone)
                if let typical = point.typicalTimeMinutes {
                    LineMark(x: .value("Time", point.recordedAt), y: .value("Typical", typical))
                        .foregroundStyle(Brand.muted.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .interpolationMethod(.monotone)
                }
            }
            .chartLegend(.hidden)
            .frame(height: 190)
        }
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(.caption2).foregroundColor(Brand.muted)
        }
    }

    /// Both directions load side by side rather than one after the other, so
    /// this page is no slower than either of the two pages it replaced.
    private func load(silent: Bool = false) async {
        guard let api = model.api else { return }
        if !silent { loading = true }
        async let nyRequest: BridgeCrossingDetail = try api.get("/api/bridge-crossings/\(facilityId)/\(BridgeCrossingDirection.towardNY.rawValue)")
        async let njRequest: BridgeCrossingDetail = try api.get("/api/bridge-crossings/\(facilityId)/\(BridgeCrossingDirection.towardNJ.rawValue)")
        let ny = try? await nyRequest
        let nj = try? await njRequest
        if ny == nil && nj == nil {
            if !silent { errorMessage = "Couldn't load crossing times. Pull to refresh to try again." }
        } else {
            toNY = ny
            toNJ = nj
            errorMessage = nil
        }
        loading = false
    }
}
