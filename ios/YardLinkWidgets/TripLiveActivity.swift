import ActivityKit
import SwiftUI
import WidgetKit

/// The Lock Screen banner and Dynamic Island for a live trip.
struct TripLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TripActivityAttributes.self) { context in
            LockScreenTrip(state: context.state)
                .padding(16)
                .activityBackgroundTint(WidgetBrand.navy)
                .activitySystemActionForegroundColor(.white)
                .widgetURL(URL(string: "yardlink://open/home"))
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: stageSymbol(state.stage))
                        .font(.title2)
                        .foregroundStyle(WidgetBrand.sky)
                        .contentTransition(.symbolEffect(.replace))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(state.statusText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(WidgetBrand.sky)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(state.equipment.isEmpty ? "Trip" : state.equipment)
                        .font(.headline)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        if let destination = state.destination {
                            Label(destination, systemImage: "mappin.and.ellipse")
                                .font(.footnote)
                                .lineLimit(1)
                        }
                        StageBar(stage: state.stage)
                        if let next = state.next {
                            Text("Next: \(next)")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(WidgetBrand.sky)
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: stageSymbol(state.stage))
                    .foregroundStyle(WidgetBrand.sky)
                    .contentTransition(.symbolEffect(.replace))
            } compactTrailing: {
                Text(shortStatus(state.stage))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(WidgetBrand.sky)
            } minimal: {
                Image(systemName: stageSymbol(state.stage))
                    .foregroundStyle(WidgetBrand.sky)
            }
            .widgetURL(URL(string: "yardlink://open/home"))
            .keylineTint(WidgetBrand.linkBlue)
        }
    }
}

private func stageSymbol(_ stage: Int) -> String {
    switch stage {
    case 0: return "shippingbox"
    case 1: return "box.truck.fill"
    case 2: return "arrow.down.to.line"
    default: return "checkmark.circle.fill"
    }
}

private func shortStatus(_ stage: Int) -> String {
    switch stage {
    case 0: return "Pickup"
    case 1: return "Rolling"
    case 2: return "Drop"
    default: return "Done"
    }
}

private struct LockScreenTrip: View {
    let state: TripActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: stageSymbol(state.stage))
                    .foregroundStyle(WidgetBrand.sky)
                    .contentTransition(.symbolEffect(.replace))
                Text(state.statusText.uppercased())
                    .font(.caption.weight(.bold))
                    .foregroundStyle(WidgetBrand.sky)
                Spacer()
                Text("Yard Link")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
            }
            Text(state.equipment.isEmpty ? "Trip" : state.equipment)
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(1)
            if let destination = state.destination {
                Label(destination, systemImage: "mappin.and.ellipse")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            }
            StageBar(stage: state.stage)
            if let next = state.next {
                Text("Next: \(next)")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
            }
        }
    }
}

/// Pickup, on the road, drop-off: three segments that fill as the trip moves.
private struct StageBar: View {
    let stage: Int

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(index <= stage ? WidgetBrand.linkBlue : Color.white.opacity(0.2))
                    .frame(height: 5)
            }
        }
        .animation(.smooth, value: stage)
    }
}
