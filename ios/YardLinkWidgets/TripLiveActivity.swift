import ActivityKit
import SwiftUI
import WidgetKit

/// The Lock Screen banner and Dynamic Island for a live trip.
///
/// The driver glances at this at 60 mph, so the three numbers that matter —
/// how long it will take, when they'll pull in, and how far it still is —
/// sit in one row everyone can read in a glance, with a rail underneath that
/// shows the run as a whole. Nothing in here is ever placed by raw pixel
/// offsets near an edge: every piece is either flowed by SwiftUI's own
/// layout or clamped to the space `GeometryReader` actually reports, so nothing
/// can land under the sensor housing or past the rounded corners.
struct TripLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TripActivityAttributes.self) { context in
            LockScreenTrip(state: context.state)
                .activityBackgroundTint(WidgetBrand.navy)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    BrandMark(compact: true)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    StatusPill(state: state)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(state.destination ?? state.equipment)
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 2)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 10) {
                        StatRow(state: state)
                        RouteRail(state: state, height: 7)
                    }
                    .padding(.top, 2)
                }
            } compactLeading: {
                TruckBadge(stage: state.stage, diameter: 22)
            } compactTrailing: {
                Text(state.ettText ?? state.distanceText ?? shortStatus(state.stage))
                    .font(.caption2.weight(.bold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(WidgetBrand.sky)
                    .lineLimit(1)
                    .frame(maxWidth: 68)
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
            VStack(alignment: .leading, spacing: 2) {
                Text(state.destination ?? "Drop-off")
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                if !state.equipment.isEmpty {
                    Text(state.equipment)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
            }
            StatRow(state: state)
            RouteRail(state: state, height: 9)
            if let next = state.next {
                Chip(text: next, symbol: "arrow.forward", filled: true)
            }
        }
        .padding(16)
        .background(Backdrop())
        .widgetURL(URL(string: "yardlink://open/home"))
    }

    private var header: some View {
        HStack(spacing: 8) {
            BrandMark(compact: false)
            Spacer(minLength: 8)
            StatusPill(state: state)
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

/// The Yard Link mark, drawn from the real logo — a small transparent-
/// background image, never typed-out text standing in for it.
private struct BrandMark: View {
    var compact: Bool

    var body: some View {
        Image("Logo")
            .resizable()
            .scaledToFit()
            .frame(height: compact ? 15 : 17)
            .accessibilityLabel("Yard Link")
    }
}

/// The three numbers that matter, in one row: how long, what clock time,
/// how far — each a fixed-width column so the dividers between them never
/// drift, and none of them can grow past the space this row is given.
private struct StatRow: View {
    let state: TripActivityAttributes.ContentState

    /// Once the trip is done there is nothing left to count down — three
    /// dashes in place of real numbers reads as broken, not finished, so
    /// this brief closing beat shows one clear line instead.
    private var isDone: Bool { state.stage >= 3 }

    var body: some View {
        if isDone {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16, weight: .bold))
                    .symbolEffect(.bounce)
                    .foregroundStyle(WidgetBrand.ok)
                Text("Trip complete")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity)
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        } else {
            HStack(spacing: 0) {
                StatCell(value: state.ettText ?? "—", caption: "ETT")
                RailDivider()
                StatCell(value: arrival, caption: "ETA")
                RailDivider()
                StatCell(value: distance, caption: "MILES AWAY")
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var arrival: String {
        guard let clock = state.arrivalClock else { return "—" }
        guard let suffix = state.arrivalSuffix, !suffix.isEmpty else { return clock }
        return "\(clock) \(suffix)"
    }

    private var distance: String {
        guard let value = state.distanceValue, let unit = state.distanceUnit else { return "—" }
        return "\(value) \(unit)"
    }
}

private struct StatCell: View {
    let value: String
    let caption: String

    var body: some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(caption)
                .font(.system(size: 9, weight: .bold))
                .kerning(0.4)
                .foregroundStyle(WidgetBrand.sky.opacity(0.85))
        }
        .frame(maxWidth: .infinity)
    }
}

/// A hairline that only ever draws between two `StatCell`s, never at an edge.
private struct RailDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.14))
            .frame(width: 1, height: 22)
    }
}

/// A round badge with the stage's icon, pulsing gently while the trip is
/// moving so the Dynamic Island never looks frozen even between fixes.
private struct TruckBadge: View {
    let stage: Int
    let diameter: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(WidgetBrand.linkBlue.opacity(0.22))
            Image(systemName: stageSymbol(stage))
                .font(.system(size: diameter * 0.5, weight: .bold))
                .foregroundStyle(WidgetBrand.sky)
                .symbolEffect(.pulse, options: .repeating, isActive: stage < 3)
        }
        .frame(width: diameter, height: diameter)
    }
}

private struct StatusPill: View {
    let state: TripActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: stageSymbol(state.stage))
                .font(.system(size: 9, weight: .bold))
                .symbolEffect(.pulse, options: .repeating, isActive: state.stage < 3)
            Text(state.statusText.uppercased())
                .font(.system(size: 9, weight: .heavy))
                .kerning(0.6)
                .lineLimit(1)
        }
        .foregroundStyle(state.stage >= 3 ? WidgetBrand.ok : WidgetBrand.sky)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule().fill((state.stage >= 3 ? WidgetBrand.ok : WidgetBrand.linkBlue).opacity(0.18))
        )
        .fixedSize()
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

/// The run as a bar: a dot at pickup, a flag at the drop-off, and the truck
/// riding the fraction between them — pulsing like the badge above so the
/// rail reads as live even on a fix that hasn't changed the number yet.
///
/// Every marker is placed with `.position(...)` inside the exact size
/// `GeometryReader` reports, clamped so a marker's own width can never push
/// it past the capsule's edges. The old version placed markers with
/// `.offset(x:)` measured from each icon's natural (unsized) position without
/// allowing for how wide the icon itself was — on a narrow Dynamic Island or
/// a large Dynamic Type setting, the flag at the end could render partly off
/// the right edge. This version cannot do that: `x` is always kept inside
/// `[half, width - half]`.
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
            let markerSize = max(height * 1.9, 16)
            let half = markerSize / 2
            let width = box.size.width
            let midY = box.size.height / 2
            let span = max(width - markerSize, 1)
            let truckX = clamp(half + span * min(max(fraction, 0), 1), half, width - half)

            ZStack {
                Capsule()
                    .fill(Color.white.opacity(0.14))
                    .frame(width: width, height: height * 0.5)
                    .position(x: width / 2, y: midY)

                let filledWidth = max(truckX - half, 0)
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [WidgetBrand.linkBlue, WidgetBrand.sky],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: filledWidth, height: height * 0.5)
                    .position(x: half + filledWidth / 2, y: midY)

                Circle()
                    .fill(.white.opacity(0.55))
                    .frame(width: height * 0.6, height: height * 0.6)
                    .position(x: half, y: midY)

                Image(systemName: "flag.checkered")
                    .font(.system(size: markerSize * 0.6, weight: .bold))
                    .foregroundStyle(state.stage >= 2 ? WidgetBrand.ok : .white.opacity(0.55))
                    .position(x: width - half, y: midY)

                Image(systemName: stageSymbol(state.stage))
                    .font(.system(size: markerSize * 0.68, weight: .black))
                    .foregroundStyle(.white)
                    .shadow(color: WidgetBrand.linkBlue.opacity(0.9), radius: 5)
                    .symbolEffect(.pulse, options: .repeating, isActive: state.stage < 3)
                    .position(x: truckX, y: midY)
            }
            .animation(.smooth, value: fraction)
        }
        .frame(height: max(height * 1.9, 16))
    }

    private func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
        min(max(value, low), high)
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
