import ActivityKit
import SwiftUI
import WidgetKit

/// The Lock Screen banner and Dynamic Island for a live trip.
///
/// The driver glances at this at 60 mph, so the two numbers that matter — how
/// far to the drop-off and when they get there — are the biggest things on it,
/// and everything else sits quietly around a rail that shows the run.
struct TripLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TripActivityAttributes.self) { context in
            LockScreenTrip(state: context.state)
                .activityBackgroundTint(.clear)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    IslandMetric(
                        value: state.distanceValue ?? "—",
                        unit: state.distanceUnit ?? "",
                        caption: "to go",
                        alignment: .leading
                    )
                }
                DynamicIslandExpandedRegion(.trailing) {
                    IslandMetric(
                        value: state.arrivalClock ?? "—",
                        unit: state.arrivalSuffix ?? "",
                        caption: "arrive",
                        alignment: .trailing
                    )
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 1) {
                        StatusFlag(state: state)
                        Text(state.destination ?? state.equipment)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 10) {
                        RouteRail(state: state, height: 8)
                        HStack(spacing: 8) {
                            if !state.equipment.isEmpty {
                                Chip(text: state.equipment, symbol: "shippingbox.fill")
                            }
                            Spacer(minLength: 0)
                            if let countdown = state.arriveBy, countdown > .now {
                                Text(countdown, style: .relative)
                                    .font(.caption2.weight(.semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(WidgetBrand.sky)
                                    .lineLimit(1)
                                    .frame(maxWidth: 92, alignment: .trailing)
                            }
                            if let next = state.next {
                                Chip(text: next, symbol: "arrow.forward", filled: true)
                            }
                        }
                    }
                    .padding(.top, 2)
                }
            } compactLeading: {
                ZStack {
                    Circle().fill(WidgetBrand.linkBlue.opacity(0.22))
                    Image(systemName: stageSymbol(state.stage))
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(WidgetBrand.sky)
                }
                .frame(width: 22, height: 22)
            } compactTrailing: {
                Text(state.distanceText ?? shortStatus(state.stage))
                    .font(.caption2.weight(.bold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(WidgetBrand.sky)
            } minimal: {
                ProgressRing(progress: state.progress, stage: state.stage)
            }
            .keylineTint(WidgetBrand.linkBlue)
            .widgetURL(URL(string: "yardlink://open/home"))
        }
    }
}

// MARK: - Lock Screen

private struct LockScreenTrip: View {
    let state: TripActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            numbers
            RouteRail(state: state, height: 10)
            footer
        }
        .padding(16)
        .background(Backdrop())
        .widgetURL(URL(string: "yardlink://open/home"))
    }

    private var header: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(state.stage >= 3 ? WidgetBrand.ok : WidgetBrand.sky)
                .frame(width: 7, height: 7)
                .shadow(color: WidgetBrand.sky.opacity(0.8), radius: 4)
            Text(state.statusText.uppercased())
                .font(.caption2.weight(.heavy))
                .kerning(1.1)
                .foregroundStyle(WidgetBrand.sky)
            Spacer()
            Text("YARD LINK")
                .font(.system(size: 9, weight: .black))
                .kerning(1.6)
                .foregroundStyle(.white.opacity(0.35))
        }
    }

    private var numbers: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Metric(
                value: state.distanceValue ?? "—",
                unit: state.distanceUnit ?? "",
                caption: state.distanceMeters == nil ? "finding you" : "to drop-off"
            )
            Spacer(minLength: 0)
            Metric(
                value: state.arrivalClock ?? "—",
                unit: state.arrivalSuffix ?? "",
                caption: countdownText,
                alignment: .trailing
            )
        }
    }

    private var countdownText: String {
        guard let arriveBy = state.arriveBy, arriveBy > .now else { return "arrival" }
        let minutes = max(1, Int(arriveBy.timeIntervalSinceNow / 60))
        return minutes < 60 ? "in \(minutes) min" : "in \(minutes / 60)h \(minutes % 60)m"
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "mappin.and.ellipse")
                .font(.caption2)
                .foregroundStyle(WidgetBrand.sky)
            Text(state.destination ?? "Drop-off")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let next = state.next {
                Chip(text: next, symbol: "arrow.forward", filled: true)
            } else if !state.equipment.isEmpty {
                Chip(text: state.equipment, symbol: "shippingbox.fill")
            }
        }
    }
}

/// Navy with a glow behind the numbers, so the banner reads as one piece of
/// glass rather than text on a slab.
private struct Backdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [WidgetBrand.navy, Color(red: 2 / 255, green: 20 / 255, blue: 38 / 255)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [WidgetBrand.linkBlue.opacity(0.35), .clear],
                center: .topLeading,
                startRadius: 4,
                endRadius: 220
            )
        }
    }
}

// MARK: - Pieces

/// A number the size of a headline with its unit tucked beside it.
private struct Metric: View {
    let value: String
    let unit: String
    let caption: String
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        VStack(alignment: alignment, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(unit)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.65))
            }
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            Text(caption)
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.4)
                .foregroundStyle(WidgetBrand.sky.opacity(0.9))
        }
    }
}

/// The same metric, sized for the island's corners.
private struct IslandMetric: View {
    let value: String
    let unit: String
    let caption: String
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        VStack(alignment: alignment, spacing: -1) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(.white)
                Text(unit)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            Text(caption)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(WidgetBrand.sky.opacity(0.85))
        }
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
    }
}

private struct StatusFlag: View {
    let state: TripActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: stageSymbol(state.stage))
                .font(.system(size: 9, weight: .bold))
            Text(state.statusText.uppercased())
                .font(.system(size: 9, weight: .heavy))
                .kerning(0.8)
        }
        .foregroundStyle(WidgetBrand.sky)
    }
}

private struct Chip: View {
    let text: String
    let symbol: String
    var filled = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold))
            Text(text).font(.system(size: 11, weight: .semibold)).lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(filled ? AnyShapeStyle(WidgetBrand.linkBlue) : AnyShapeStyle(Color.white.opacity(0.12)))
        )
        .foregroundStyle(.white)
    }
}

/// Origin dot, a trail that fills as the miles fall away, the truck sitting
/// where the driver is, and the flag at the drop-off.
private struct RouteRail: View {
    let state: TripActivityAttributes.ContentState
    var height: CGFloat

    private var fraction: Double { state.progress ?? stageFraction }

    private var stageFraction: Double {
        switch state.stage {
        case 0: return 0.02
        case 1: return 0.4
        case 2: return 0.92
        default: return 1
        }
    }

    var body: some View {
        GeometryReader { box in
            let inset = height * 1.6
            let span = max(box.size.width - inset * 2, 1)
            let x = inset + span * min(max(fraction, 0), 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.14))
                    .frame(height: height * 0.5)
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [WidgetBrand.linkBlue, WidgetBrand.sky],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: x, height: height * 0.5)
                Circle()
                    .fill(.white.opacity(0.5))
                    .frame(width: height * 0.5, height: height * 0.5)
                    .offset(x: inset - height * 0.25)
                Image(systemName: "flag.checkered")
                    .font(.system(size: height * 0.95, weight: .bold))
                    .foregroundStyle(state.stage >= 2 ? WidgetBrand.ok : .white.opacity(0.55))
                    .offset(x: box.size.width - inset - height * 0.5)
                Image(systemName: stageSymbol(state.stage))
                    .font(.system(size: height * 1.15, weight: .black))
                    .foregroundStyle(.white)
                    .shadow(color: WidgetBrand.linkBlue.opacity(0.9), radius: 5)
                    .offset(x: x - height * 0.9)
            }
            .frame(height: box.size.height, alignment: .center)
            .animation(.smooth, value: fraction)
        }
        .frame(height: height * 1.6)
    }
}

/// The minimal island: a ring that closes as the drop-off gets near.
private struct ProgressRing: View {
    let progress: Double?
    let stage: Int

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.2), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: max(0.04, progress ?? 0.05))
                .stroke(
                    AngularGradient(colors: [WidgetBrand.linkBlue, WidgetBrand.sky], center: .center),
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            Image(systemName: stageSymbol(stage))
                .font(.system(size: 8, weight: .black))
                .foregroundStyle(WidgetBrand.sky)
        }
        .padding(1)
    }
}

// MARK: - Words

private func stageSymbol(_ stage: Int) -> String {
    switch stage {
    case 0: return "shippingbox.fill"
    case 1: return "box.truck.fill"
    case 2: return "arrow.down.to.line"
    default: return "checkmark.seal.fill"
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
