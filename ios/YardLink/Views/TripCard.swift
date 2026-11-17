import SwiftUI

/// The trip in hand, laid out as on the web app: the painted number large and
/// centred, the facts beneath it, and the route on a navy strip.
struct TripCard: View {
    struct Content {
        var status: String?
        var isBareChassis = false
        var containerNumber: String?
        var chassisNumber: String?
        var equipmentType: String?
        var containerType: String?
        var isLoaded = false
        var sealNumber: String?
        var originName: String?
        var destinationName: String?
    }

    let content: Content
    /// Shown as "Change" beside the drop-off when the trip can still be re-routed.
    var onChangeDropoff: (() -> Void)?
    /// A loaded live trip lets the driver correct the seal.
    var onEditSeal: (() -> Void)?

    private var headline: String {
        if content.isBareChassis { return content.chassisNumber ?? "Chassis" }
        let formatted = Marking.formatContainer(content.containerNumber)
        return formatted.isEmpty ? (content.containerNumber ?? "Trip") : formatted
    }

    private var liveStatus: String? {
        guard let status = content.status, status != "COMPLETED" else { return nil }
        return status
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                if let liveStatus {
                    StatusPill(text: Words.tripStatus(liveStatus), color: tripStatusColor(liveStatus))
                }

                Text(headline)
                    .font(.system(size: 30, weight: .bold, design: .monospaced))
                    .tracking(1)
                    .foregroundColor(Brand.navy)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(content.isBareChassis ? "Chassis \(headline)" : "Container \(headline)")
                    .copyable(
                        headline,
                        label: content.isBareChassis ? "Chassis" : "Container",
                        kind: content.isBareChassis ? .chassis : .container
                    )

                Divider()

                HStack(alignment: .top, spacing: 8) {
                    FactCell(label: "Length", value: content.isBareChassis ? "—" : (Words.size(content.equipmentType) ?? "—"))
                    FactCell(label: "Chassis", value: content.chassisNumber ?? "None", mono: content.chassisNumber != nil, copyKind: .chassis)
                    sealCell
                }

                HStack(alignment: .top, spacing: 8) {
                    FactCell(label: "Type", value: content.isBareChassis ? "Bare chassis" : (Words.line(content.containerType) ?? "—"))
                    FactCell(label: "Load", value: !content.isBareChassis && content.isLoaded ? "Loaded" : "Empty", alignment: .trailing)
                }
            }
            .padding(16)

            RouteStrip(
                originName: content.originName,
                destinationName: content.destinationName,
                onChangeDropoff: onChangeDropoff
            )
        }
        .cardSurface()
    }

    @ViewBuilder
    private var sealCell: some View {
        let seal = content.isBareChassis ? nil : content.sealNumber
        if let onEditSeal {
            Button(action: onEditSeal) {
                HStack(alignment: .top, spacing: 4) {
                    FactCell(label: "Seal", value: (seal?.isEmpty == false ? seal : nil) ?? "—", mono: true, copyOnTap: false, copyKind: .seal)
                    Image(systemName: "pencil")
                        .font(.caption.weight(.bold))
                        .foregroundColor(Brand.linkBlue)
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint("Corrects the seal number")
        } else {
            FactCell(label: "Seal", value: (seal?.isEmpty == false ? seal : nil) ?? "—", mono: true, copyKind: .seal)
        }
    }
}

/// Pickup on the left, drop-off on the right, joined by a track.
struct RouteStrip: View {
    let originName: String?
    let destinationName: String?
    var onChangeDropoff: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            point(name: originName ?? "Not set", label: "Pickup", alignment: .leading)

            HStack(spacing: 4) {
                dot(on: originName != nil)
                Rectangle().fill(Color.white.opacity(0.3)).frame(height: 2)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundColor(Brand.sky)
                Rectangle().fill(Color.white.opacity(0.3)).frame(height: 2)
                dot(on: destinationName != nil)
            }
            .frame(width: 84)
            .padding(.top, 6)
            .accessibilityHidden(true)

            VStack(alignment: .trailing, spacing: 4) {
                point(name: destinationName ?? "Choose at drop-off", label: "Drop-off", alignment: .trailing)
                if let onChangeDropoff {
                    Button("Change", action: onChangeDropoff)
                        .font(.caption.weight(.bold))
                        .foregroundColor(Brand.sky)
                        .frame(minHeight: 28)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(Brand.navy)
    }

    private func dot(on: Bool) -> some View {
        Circle()
            .fill(on ? Brand.sky : Color.clear)
            .overlay(Circle().stroke(on ? Brand.sky : Color.white.opacity(0.5), lineWidth: 2))
            .frame(width: 9, height: 9)
    }

    private func point(name: String, label: String, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(name)
                .font(.subheadline.weight(.bold))
                .foregroundColor(.white)
                .multilineTextAlignment(alignment == .trailing ? .trailing : .leading)
                .lineLimit(2)
            Text(label.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(0.7)
                .foregroundColor(Color.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity, alignment: alignment == .trailing ? .trailing : .leading)
        .accessibilityElement(children: .combine)
    }
}
