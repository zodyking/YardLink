import SwiftUI
import WidgetKit

struct TripEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct TripProvider: TimelineProvider {
    func placeholder(in context: Context) -> TripEntry {
        var sample = WidgetSnapshot()
        sample.signedIn = true
        sample.trip = WidgetTrip(
            container: "MSCU 123456",
            chassis: "TRLU 654321",
            destination: "APM Terminals",
            status: "IN_TRANSIT",
            next: "Arrive",
            live: true
        )
        return TripEntry(date: Date(), snapshot: sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (TripEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : TripEntry(date: Date(), snapshot: SharedStore.loadSnapshot()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TripEntry>) -> Void) {
        Task {
            let snapshot = await WidgetData.refresh()
            let next = Date().addingTimeInterval(10 * 60)
            completion(Timeline(entries: [TripEntry(date: Date(), snapshot: snapshot)], policy: .after(next)))
        }
    }
}

struct TripWidget: Widget {
    static let kind = "YardLinkTrip"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: TripProvider()) { entry in
            TripWidgetView(entry: entry)
        }
        .configurationDisplayName("Current Trip")
        .description("The container and chassis you have, where it is going, and what comes next.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}

struct TripWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TripEntry

    private var trip: WidgetTrip? { entry.snapshot.trip }

    var body: some View {
        content
            .widgetURL(URL(string: "yardlink://open/home"))
            .containerBackground(for: .widget) { WidgetBrand.navy }
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryInline:
            Text(trip.map { "\($0.statusText): \($0.equipment)" } ?? "No trip")
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Text(trip?.statusText ?? "No trip").font(.headline).widgetAccentable()
                if let trip {
                    Text(trip.equipment).font(.caption).lineLimit(1)
                    if let destination = trip.destination { Text("To \(destination)").font(.caption2).lineLimit(1) }
                }
            }
        default:
            card
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !entry.snapshot.signedIn {
                Text("Yard Link")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("Open the app and sign in.")
                    .font(.footnote)
                    .foregroundStyle(WidgetBrand.sky)
            } else if let trip {
                Text(trip.statusText.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(WidgetBrand.sky)
                Text(trip.equipment.isEmpty ? "Trip" : trip.equipment)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                if let destination = trip.destination {
                    Label(destination, systemImage: "mappin.and.ellipse")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if family == .systemMedium, trip.live, let next = trip.next {
                    Text("Next: \(next)")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(WidgetBrand.linkBlue, in: Capsule())
                        .foregroundStyle(.white)
                }
            } else {
                Text("No trip right now")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("Start a pickup in the app.")
                    .font(.footnote)
                    .foregroundStyle(WidgetBrand.sky)
            }
            if !(family == .systemMedium && trip?.live == true) { Spacer(minLength: 0) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
