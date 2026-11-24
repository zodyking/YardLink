import SwiftUI

/// Fires when the bar's already-selected item is tapped again. A plain tab
/// switch just changes `selection`; this is the extra "tap again" signal
/// each tab's own view listens for so it can pop its navigation stack back
/// to its root, the way the system tab bar does for free.
final class TabRootTap: ObservableObject {
    static let shared = TabRootTap()

    /// UUID-stamped so two taps on the same tab are never treated as the
    /// "same" value and silently skipped by `.onChange`.
    struct Event: Equatable {
        let screen: AnyHashable
        let id = UUID()
    }

    @Published private(set) var event: Event?

    private init() {}

    func fire<Screen: Hashable>(_ screen: Screen) {
        event = Event(screen: AnyHashable(screen))
    }
}

/// The bottom bar, drawn to match the web app: a white bar with a hairline
/// top rule, five destinations, and Tasks raised on a blue disc in the
/// middle. It is chrome — it stays put while each tab scrolls behind it.
struct DriverTabBar<Screen: Hashable>: View {
    struct Item: Identifiable {
        let screen: Screen
        let label: String
        let glyph: TabGlyph.Name
        /// Drawn as the raised disc. One item at most.
        var raised = false
        var badge = 0

        var id: Screen { screen }
    }

    let items: [Item]
    @Binding var selection: Screen

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(items) { item in
                Button {
                    if selection == item.screen {
                        TabRootTap.shared.fire(item.screen)
                    } else {
                        selection = item.screen
                    }
                } label: {
                    if item.raised {
                        raisedLabel(item)
                    } else {
                        flatLabel(item)
                    }
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .accessibilityLabel(item.badge > 0 ? "\(item.label), \(item.badge) unread" : item.label)
                .accessibilityAddTraits(selection == item.screen ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(.top, 6)
        .frame(height: 64, alignment: .top)
        .frame(maxWidth: .infinity)
        // The hairline sits behind the bar's own content, so the raised
        // disc (which pokes up past the top edge on purpose) is drawn in
        // front of it and covers it, rather than the line cutting across.
        //
        // It gets its own background, separate from the paper fill. When
        // both shared one, the paper's ignoresSafeArea stretched that shared
        // box down into the home-indicator area, and the line was laid out
        // against the stretched box instead of the bar. That pushed it about
        // 30pt down, through the middle of the icons and labels. On its own
        // background the line is laid out against the bar's frame alone, so
        // .top really is the bar's top edge.
        .background(alignment: .top) {
            Rectangle().fill(Brand.line).frame(height: 1)
        }
        .background(Brand.paper.ignoresSafeArea(edges: .bottom))
    }

    private func flatLabel(_ item: Item) -> some View {
        VStack(spacing: 3) {
            TabGlyph(name: item.glyph)
                .frame(width: 22, height: 22)
                .foregroundColor(selection == item.screen ? Brand.linkBlue : Brand.muted)
                .overlay(alignment: .topTrailing) {
                    if item.badge > 0 {
                        Text(item.badge > 9 ? "9+" : "\(item.badge)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Brand.danger)
                            .clipShape(Capsule())
                            .offset(x: 10, y: -6)
                    }
                }
            Text(item.label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(selection == item.screen ? Brand.navy : Brand.muted)
        }
        .frame(minWidth: 44, minHeight: 50)
        .contentShape(Rectangle())
    }

    /// The raised disc sits above the bar's top rule, as on the web.
    private func raisedLabel(_ item: Item) -> some View {
        VStack(spacing: 3) {
            TabGlyph(name: item.glyph)
                .frame(width: 26, height: 26)
                .foregroundColor(Brand.navyDeep)
                .frame(width: 52, height: 52)
                .background(
                    LinearGradient(colors: [Brand.sky, Brand.linkBlue], startPoint: .top, endPoint: .bottom),
                    in: Circle()
                )
                .overlay(Circle().stroke(Brand.paper, lineWidth: 4))
                // Kept subtle so it reads as "raised" without a heavy smudge
                // on the bar around the disc.
                .shadow(color: Brand.navy.opacity(0.15), radius: 3, y: 2)
                .offset(y: -22)
            Text(item.label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(selection == item.screen ? Brand.navy : Brand.muted)
                .offset(y: -18)
        }
        .frame(minWidth: 44, minHeight: 50)
        .contentShape(Rectangle())
    }
}

/// The tab icons, drawn on the same 24-unit grid and in the same weight as
/// the web app's, so the two bars read as one design.
struct TabGlyph: View {
    enum Name {
        case home, trips, tasks, containers, more
    }

    let name: Name

    var body: some View {
        GeometryReader { geometry in
            let unit = min(geometry.size.width, geometry.size.height) / 24
            let weight = (name == .containers ? 1.8 : 2) * unit

            Path { path in
                func move(_ x: CGFloat, _ y: CGFloat) { path.move(to: CGPoint(x: x * unit, y: y * unit)) }
                func line(_ x: CGFloat, _ y: CGFloat) { path.addLine(to: CGPoint(x: x * unit, y: y * unit)) }
                func box(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ radius: CGFloat) {
                    path.addRoundedRect(
                        in: CGRect(x: x * unit, y: y * unit, width: width * unit, height: height * unit),
                        cornerSize: CGSize(width: radius * unit, height: radius * unit)
                    )
                }
                func ring(_ x: CGFloat, _ y: CGFloat, _ radius: CGFloat) {
                    path.addEllipse(in: CGRect(
                        x: (x - radius) * unit,
                        y: (y - radius) * unit,
                        width: radius * 2 * unit,
                        height: radius * 2 * unit
                    ))
                }
                /// A tick, as in the task list rows.
                func tick(_ y: CGFloat) {
                    move(4.2, y)
                    line(5.6, y + 1.4)
                    line(8, y - 1.4)
                }

                switch name {
                case .home:
                    move(4.4, 11.2)
                    line(12, 4.6)
                    line(19.6, 11.2)
                    move(6.4, 10.3)
                    line(6.4, 20)
                    line(10.5, 20)
                    line(10.5, 14.6)
                    line(13.5, 14.6)
                    line(13.5, 20)
                    line(17.6, 20)
                    line(17.6, 10.3)

                case .trips:
                    ring(6.4, 17.7, 2.35)
                    ring(17.6, 6.3, 2.35)
                    move(8.6, 17.7)
                    line(15, 17.7)
                    path.addArc(
                        center: CGPoint(x: 15 * unit, y: 14.4 * unit),
                        radius: 3.3 * unit,
                        startAngle: .degrees(90),
                        endAngle: .degrees(-90),
                        clockwise: false
                    )
                    line(9.2, 11.1)
                    path.addArc(
                        center: CGPoint(x: 9.2 * unit, y: 7.8 * unit),
                        radius: 3.3 * unit,
                        startAngle: .degrees(90),
                        endAngle: .degrees(270),
                        clockwise: true
                    )
                    line(15, 4.5)

                case .tasks:
                    for y in [6.2, 12.0, 17.8] as [CGFloat] {
                        move(9.2, y)
                        line(19.6, y)
                        tick(y)
                    }

                case .containers:
                    box(3.4, 4, 17.2, 16, 1.3)
                    move(3.4, 6.6)
                    line(20.6, 6.6)
                    move(12, 6.6)
                    line(12, 20)
                    move(7.7, 8.4)
                    line(7.7, 18)
                    move(16.3, 8.4)
                    line(16.3, 18)
                    move(6.6, 13.2)
                    line(8.8, 13.2)
                    move(15.2, 13.2)
                    line(17.4, 13.2)

                case .more:
                    box(3.4, 3.4, 7.2, 7.2, 1.4)
                    box(13.4, 3.4, 7.2, 7.2, 1.4)
                    box(3.4, 13.4, 7.2, 7.2, 1.4)
                    box(13.4, 13.4, 7.2, 7.2, 1.4)
                }
            }
            .stroke(style: StrokeStyle(lineWidth: weight, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}
