import SwiftUI
import WidgetKit

struct QuickActionsEntry: TimelineEntry {
    let date: Date
}

struct QuickActionsProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuickActionsEntry { QuickActionsEntry(date: Date()) }

    func getSnapshot(in context: Context, completion: @escaping (QuickActionsEntry) -> Void) {
        completion(QuickActionsEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuickActionsEntry>) -> Void) {
        completion(Timeline(entries: [QuickActionsEntry(date: Date())], policy: .never))
    }
}

/// Three taps to the places a driver goes most.
struct QuickActionsWidget: Widget {
    static let kind = "YardLinkQuickActions"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: QuickActionsProvider()) { _ in
            QuickActionsView()
        }
        .configurationDisplayName("Quick Actions")
        .description("Jump straight to your trip, tasks or messages.")
        .supportedFamilies([.systemMedium])
    }
}

private struct QuickActionsView: View {
    private let actions: [(title: String, symbol: String, screen: String)] = [
        ("Trip", "shippingbox.fill", "home"),
        ("Tasks", "checklist", "tasks"),
        ("Messages", "bubble.left.and.bubble.right.fill", "messages"),
    ]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(actions, id: \.screen) { action in
                Link(destination: URL(string: "yardlink://open/\(action.screen)")!) {
                    VStack(spacing: 8) {
                        Image(systemName: action.symbol)
                            .font(.title2)
                            .foregroundStyle(.white)
                        Text(action.title)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(WidgetBrand.linkBlue, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
        .containerBackground(for: .widget) { WidgetBrand.navy }
    }
}
