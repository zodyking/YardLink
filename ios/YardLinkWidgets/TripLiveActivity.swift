import ActivityKit
import SwiftUI
import WidgetKit

/// The Lock Screen banner and Dynamic Island for a live trip: how far the
/// drop-off is and how long it will take, with the trip's stage as the fallback
/// until the phone has a position.
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
                    VStack(alignment: .leading, spacing: 2) {
                        Image(systemName: stageSymbol(state.stage))
                            .font(.title3)
                            .foregroundStyle(WidgetBrand.sky)
                            .contentTransition(.symbolEffect(.replace))
                        Text(state.distanceText ?? state.statusText)
                            .font(.title2.weight(.bold))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .minimumScaleFactor(0.7)
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("ETA")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(WidgetBrand.sky)
                        TimeLeft(state: state)
                            .font(.title3.weight(.semibold))
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(state.destination ?? state.equipment)
                        .font(.subheadline)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        TripBar(state: state)
                        HStack {
                            Text(state.equipment.isEmpty ? state.statusText : state.equipment)
                                .lineLimit(1)
                            Spacer()
                            if let next = state.next { Text(next).fontWeight(.semibold).foregroundStyle(WidgetBrand.sky) }
                        }
                        .font(.footnote)
                    }
                }
            } compactLeading: {
                Image(systemName: stageSymbol(state.stage))
                    .foregroundStyle(WidgetBrand.sky)
                    .contentTransition(.symbolEffect(.replace))
            } compactTrailing: {
                Text(state.distanceText ?? shortStatus(state.stage))
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
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

/// Minutes left, counting down by itself between updates.
private struct TimeLeft: View {
    let state: TripActivityAttributes.ContentState

    var body: some View {
        if let arriveBy = state.arriveBy, arriveBy > Date() {
            Text(arriveBy, style: .relative)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        } else {
            Text("—")
        }
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
            HStack(alignment: .firstTextBaseline) {
                Text(state.distanceText ?? "Locating…")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(.white)
                Text("to drop-off")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                if state.arriveBy != nil {
                    VStack(alignment: .trailing, spacing: 0) {
                        TimeLeft(state: state)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white)
                        Text("ETA")
                            .font(.caption2)
                            .foregroundStyle(WidgetBrand.sky)
                    }
                }
            }
            TripBar(state: state)
            HStack {
                Text(state.destination ?? state.equipment)
                    .lineLimit(1)
                Spacer()
                if let next = state.next { Text("Next: \(next)").fontWeight(.semibold) }
            }
            .font(.footnote)
            .foregroundStyle(.white.opacity(0.85))
        }
    }
}

/// Fills as the drop-off gets closer. Before the phone has a position it shows
/// the three trip stages instead.
private struct TripBar: View {
    let state: TripActivityAttributes.ContentState

    var body: some View {
        if let progress = state.progress {
            GeometryReader { box in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.2))
                    Capsule()
                        .fill(WidgetBrand.linkBlue)
                        .frame(width: max(8, box.size.width * progress))
                }
            }
            .frame(height: 6)
            .animation(.smooth, value: progress)
        } else {
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    Capsule()
                        .fill(index <= state.stage ? WidgetBrand.linkBlue : Color.white.opacity(0.2))
                        .frame(height: 6)
                }
            }
            .animation(.smooth, value: state.stage)
        }
    }
}
