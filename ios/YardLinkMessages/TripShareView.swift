import SwiftUI
import UIKit

/// What goes into the thread: the lines Messages shows on the bubble, the
/// picture above them, and what the notification reads as.
struct TripCard {
    let caption: String
    let subcaption: String?
    let trailing: String?
    let summary: String
    let query: [URLQueryItem]
    let image: UIImage?
}

/// The Yard Link drawer inside Messages.
struct TripShareView: View {
    let snapshot: WidgetSnapshot
    let compact: Bool
    let onExpand: () -> Void
    let onSend: (TripCard) -> Void

    private var trip: WidgetTrip? { snapshot.trip }

    var body: some View {
        ZStack {
            WidgetBrand.navy.ignoresSafeArea()
            content.padding(compact ? 12 : 20)
        }
    }

    @ViewBuilder
    private var content: some View {
        if !snapshot.signedIn {
            note("Open Yard Link and sign in", detail: "Then your run can be shared from here.")
        } else if let trip {
            if compact {
                Button(action: onExpand) {
                    HStack(spacing: 10) {
                        Image(systemName: "box.truck.fill").foregroundStyle(WidgetBrand.sky)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(trip.equipment.isEmpty ? "Current trip" : trip.equipment)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Text("Tap to share your run")
                                .font(.caption2)
                                .foregroundStyle(WidgetBrand.sky)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.up").font(.caption).foregroundStyle(.white.opacity(0.6))
                    }
                }
                .buttonStyle(.plain)
            } else {
                expanded(trip)
            }
        } else {
            note("No trip right now", detail: "Start a pickup in Yard Link and it shows up here.")
        }
    }

    private func expanded(_ trip: WidgetTrip) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("SHARE YOUR RUN")
                .font(.caption2.weight(.heavy))
                .kerning(1.2)
                .foregroundStyle(WidgetBrand.sky)

            choice(
                title: "Status",
                detail: [trip.statusText, trip.destination.map { "to \($0)" }]
                    .compactMap { $0 }.joined(separator: " "),
                symbol: "paperplane.fill"
            ) { onSend(statusCard(trip)) }

            if let destination = trip.destination {
                choice(title: "Where I'm headed", detail: destination, symbol: "mappin.and.ellipse") {
                    onSend(destinationCard(trip, destination: destination))
                }
            }

            if !trip.equipment.isEmpty {
                choice(title: "Equipment", detail: trip.equipment, symbol: "shippingbox.fill") {
                    onSend(equipmentCard(trip))
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func choice(title: String, detail: String, symbol: String, act: @escaping () -> Void) -> some View {
        Button(action: act) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(WidgetBrand.sky)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(WidgetBrand.linkBlue.opacity(0.2)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    Text(detail).font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.circle.fill").foregroundStyle(WidgetBrand.linkBlue)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }

    private func note(_ title: String, detail: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
            Text(detail).font(.caption).foregroundStyle(WidgetBrand.sky).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: The cards

    private func statusCard(_ trip: WidgetTrip) -> TripCard {
        TripCard(
            caption: trip.equipment.isEmpty ? "Yard Link" : trip.equipment,
            subcaption: trip.statusText,
            trailing: trip.destination,
            summary: "\(trip.statusText)\(trip.destination.map { " to \($0)" } ?? "")",
            query: [URLQueryItem(name: "kind", value: "status")],
            image: TripCardArt.draw(headline: trip.statusText, detail: trip.equipment)
        )
    }

    private func destinationCard(_ trip: WidgetTrip, destination: String) -> TripCard {
        TripCard(
            caption: destination,
            subcaption: "Headed here",
            trailing: trip.equipment.isEmpty ? nil : trip.equipment,
            summary: "Headed to \(destination)",
            query: [URLQueryItem(name: "kind", value: "destination")],
            image: TripCardArt.draw(headline: "Headed to", detail: destination)
        )
    }

    private func equipmentCard(_ trip: WidgetTrip) -> TripCard {
        TripCard(
            caption: trip.equipment,
            subcaption: trip.statusText,
            trailing: nil,
            summary: "Equipment: \(trip.equipment)",
            query: [URLQueryItem(name: "kind", value: "equipment")],
            image: TripCardArt.draw(headline: "On the truck", detail: trip.equipment)
        )
    }
}

/// The picture on the bubble, drawn rather than shipped, so it always says
/// what this particular run is.
enum TripCardArt {
    static func draw(headline: String, detail: String) -> UIImage? {
        let size = CGSize(width: 600, height: 300)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(red: 5 / 255, green: 37 / 255, blue: 67 / 255, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor(red: 0, green: 125 / 255, blue: 224 / 255, alpha: 0.35).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: -120, y: -170, width: 420, height: 420))

            let sky = UIColor(red: 93 / 255, green: 174 / 255, blue: 254 / 255, alpha: 1)
            write("YARD LINK", at: CGPoint(x: 36, y: 34), font: .systemFont(ofSize: 20, weight: .heavy), color: sky.withAlphaComponent(0.8))
            write(headline.uppercased(), at: CGPoint(x: 36, y: 92), font: .systemFont(ofSize: 26, weight: .semibold), color: sky)
            write(detail, at: CGPoint(x: 36, y: 136), font: .systemFont(ofSize: 44, weight: .bold), color: .white, width: size.width - 72)
        }
    }

    private static func write(
        _ text: String,
        at point: CGPoint,
        font: UIFont,
        color: UIColor,
        width: CGFloat = .greatestFiniteMagnitude
    ) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
        let bounds = CGRect(origin: point, size: CGSize(width: width, height: font.lineHeight * 2))
        (text as NSString).draw(with: bounds, options: [.usesLineFragmentOrigin], attributes: attributes, context: nil)
    }
}
