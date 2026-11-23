import SwiftUI
import Charts

/// Live Hudson River crossing times from the Port Authority, grouped by
/// crossing with New York– and New Jersey–bound side by side. The George
/// Washington Bridge's lower level is never shown — "the GWB" here always
/// means its upper level, its only facility with a level split.
struct BridgeCrossingsListView: View {
    @EnvironmentObject private var model: AppModel

    @State private var lanes: [BridgeCrossingLane] = []
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

                if loading {
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
        .refreshable { await load() }
    }

    private func crossingCard(name: String, lanes: [BridgeCrossingLane]) -> some View {
        Card {
            Text(name).font(.body.weight(.semibold)).foregroundColor(Brand.navy)
            VStack(spacing: 8) {
                ForEach(lanes) { lane in
                    NavigationLink {
                        BridgeCrossingDetailView(facilityId: lane.facilityId, direction: lane.direction, crossingName: name)
                    } label: {
                        laneRow(lane)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func laneRow(_ lane: BridgeCrossingLane) -> some View {
        HStack(spacing: 10) {
            Text(lane.direction == .towardNY ? "To NY" : "To NJ")
                .font(.footnote.weight(.semibold))
                .foregroundColor(Brand.muted)
                .frame(width: 48, alignment: .leading)

            if lane.isClosed {
                Text("Closed")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Brand.danger)
            } else {
                Text("\(lane.travelTimeMinutes) min")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Brand.navy)
            }

            TrendBadge(trend: lane.trend)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundColor(Brand.muted.opacity(0.6))
        }
        .padding(.vertical, 2)
    }

    private func load() async {
        guard let api = model.api else { return }
        errorMessage = nil
        do {
            let list: BridgeCrossingLaneList = try await api.get("/api/bridge-crossings")
            lanes = list.lanes
        } catch {
            errorMessage = model.handle(error)
        }
        loading = false
    }
}

/// Small "improving / worsening / steady" pill, shared by the list and detail screens.
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
            .font(.caption.weight(.semibold))
            .foregroundColor(style.color)
            .labelStyle(.titleAndIcon)
    }
}

/// One crossing's last 24 hours: the current reading, its trend, and a graph
/// against the feed's own typical time for that lane.
struct BridgeCrossingDetailView: View {
    @EnvironmentObject private var model: AppModel
    let facilityId: Int
    let direction: BridgeCrossingDirection
    let crossingName: String

    @State private var detail: BridgeCrossingDetail?
    @State private var loading = true
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let errorMessage { ErrorBanner(message: errorMessage) }

                if let detail {
                    header(detail.lane)
                    if detail.history.count > 1 {
                        graph(detail.history)
                    } else {
                        EmptyNote(
                            title: "Not enough history yet",
                            detail: "Check back in a bit — the graph fills in as readings come in."
                        )
                    }
                } else if loading {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(16)
        }
        .screenBackground()
        .navigationTitle(crossingName)
        .navigationBarTitleDisplayMode(.inline)
        .lightBar()
        .task { await load() }
        .refreshable { await load() }
    }

    private func header(_ lane: BridgeCrossingLane) -> some View {
        Card {
            Text(lane.direction == .towardNY ? "Toward New York" : "Toward New Jersey")
                .font(.footnote.weight(.semibold))
                .foregroundColor(Brand.muted)

            if lane.isClosed {
                Text("Closed").font(.system(size: 34, weight: .bold)).foregroundColor(Brand.danger)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(lane.travelTimeMinutes)").font(.system(size: 40, weight: .bold)).foregroundColor(Brand.navy)
                    Text("min").font(.title3).foregroundColor(Brand.muted)
                }
            }

            TrendBadge(trend: lane.trend)

            if let typical = lane.typicalTimeMinutes {
                Text("Typically \(typical) min").font(.footnote).foregroundColor(Brand.muted)
            }
        }
    }

    private func graph(_ history: [BridgeCrossingHistoryPoint]) -> some View {
        Card {
            Text("Past 24 hours").font(.footnote.weight(.semibold)).foregroundColor(Brand.muted)
            Chart(history) { point in
                LineMark(x: .value("Time", point.recordedAt), y: .value("Minutes", point.travelTimeMinutes))
                    .foregroundStyle(Brand.linkBlue)
                    .interpolationMethod(.monotone)
                if let typical = point.typicalTimeMinutes {
                    LineMark(x: .value("Time", point.recordedAt), y: .value("Typical", typical))
                        .foregroundStyle(Brand.muted.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                }
            }
            .frame(height: 180)
        }
    }

    private func load() async {
        guard let api = model.api else { return }
        errorMessage = nil
        do {
            let result: BridgeCrossingDetail = try await api.get("/api/bridge-crossings/\(facilityId)/\(direction.rawValue)")
            detail = result
        } catch {
            errorMessage = model.handle(error)
        }
        loading = false
    }
}
