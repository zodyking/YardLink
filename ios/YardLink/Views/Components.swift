import SwiftUI
import UIKit

enum Format {
    private static let dayTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let dayOnly: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMM d"
        return formatter
    }()

    private static let iso: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    static func dateTime(_ date: Date?) -> String {
        guard let date else { return "—" }
        return dayTime.string(from: date)
    }

    static func day(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return dayOnly.string(from: date)
    }

    /// "2026-11-15" → "Today" / "Sunday, Nov 15".
    static func day(iso text: String?) -> String {
        guard let text, let date = iso.date(from: text) else { return "Undated" }
        return day(date)
    }

    /// "2026-11-15" → midnight that day, or nil if it doesn't parse.
    static func date(iso text: String?) -> Date? {
        guard let text else { return nil }
        return iso.date(from: text)
    }
}

/// Label on the left, value on the right; hidden when there is no value.
struct InfoRow: View {
    let label: String
    let value: String?

    /// "Container", "Chassis" and "Seal" rows copy in pieces, as on the web.
    private var copyKind: CopyPart.Kind {
        switch label.lowercased() {
        case "container": return .container
        case "chassis": return .chassis
        case "seal", "seal number": return .seal
        default: return .plain
        }
    }

    var body: some View {
        if let value, !value.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(label)
                    .font(.subheadline)
                    .foregroundColor(Brand.muted)
                    .frame(width: 92, alignment: .leading)
                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Brand.navy)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .copyable(value, label: label, kind: copyKind)
            }
        }
    }
}

struct SectionTitle: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.bold))
            .foregroundColor(Brand.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
    }
}

/// Painted equipment number, in the monospaced face used across the app.
struct EquipmentNumber: View {
    let text: String
    var font: Font = .system(.title3, design: .monospaced)
    /// Names the number in the "copied" note, e.g. Container.
    var label: String? = nil
    /// Off inside a row that opens something, where a tap has to navigate.
    var copyOnTap = true
    var kind: CopyPart.Kind = .plain

    var body: some View {
        Text(text)
            .font(font.weight(.bold))
            .foregroundColor(Brand.navy)
            .copyable(text, label: label, onTap: copyOnTap, kind: kind)
    }
}

/// One line of a history timeline: what, where, who, when.
struct TimelineRow: View {
    let symbol: String
    let title: String
    let lines: [String]
    let date: Date?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .foregroundColor(Brand.linkBlue)
                .frame(width: 22)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Brand.navy)
                ForEach(lines, id: \.self) { line in
                    Text(line)
                        .font(.footnote)
                        .foregroundColor(Brand.muted)
                }
                Text(Format.dateTime(date))
                    .font(.caption)
                    .foregroundColor(Brand.muted)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

extension HistoryEvent {
    /// Steps on the way to a pickup or drop-off, and paperwork, are not
    /// moves of the equipment; the history reads better without them.
    var isShownInHistory: Bool {
        !["PICKUP_STARTED", "DROPOFF_STARTED", "DOCUMENT_ADDED", "STATUS_CHANGE"].contains(eventType)
    }

    /// Where, who, and the other piece of equipment involved.
    func detailLines(showContainer: Bool, showChassis: Bool) -> [String] {
        var lines: [String] = []
        if let locationName, !locationName.isEmpty { lines.append("At \(locationName)") }
        if let driverName, !driverName.isEmpty { lines.append("By \(driverName)") }
        if showContainer, let containerNumber, !containerNumber.isEmpty { lines.append("Container \(containerNumber)") }
        if showChassis, let chassisNumber, !chassisNumber.isEmpty { lines.append("Chassis \(chassisNumber)") }
        if let sealNumber, !sealNumber.isEmpty { lines.append("Seal \(sealNumber)") }
        if let notes, !notes.isEmpty { lines.append(notes) }
        return lines
    }
}

/// Tap to dial a site phone line.
/// A phone line with the two things a driver does with it: ring it, or text
/// it from their own number through the phone's Messages app.
struct PhoneRow: View {
    let label: String
    let number: String?
    /// Written into the text for the driver, e.g. the trip update.
    var messageBody: String = ""

    @State private var texting = false

    private var digits: String { (number ?? "").filter { $0.isNumber || $0 == "+" } }

    var body: some View {
        if let number, !number.isEmpty {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.footnote).foregroundColor(Brand.muted)
                    Text(number)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(Brand.navy)
                        .copyable(number, label: label)
                }
                Spacer(minLength: 0)

                if MessageComposer.isAvailable {
                    Button {
                        texting = true
                    } label: {
                        Image(systemName: "message.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(Brand.linkBlue)
                    .frame(width: 44, height: 44)
                    .accessibilityLabel("Text \(label)")
                }

                if let url = URL(string: "tel://\(digits)") {
                    Link(destination: url) {
                        Image(systemName: "phone.fill")
                            .foregroundColor(Brand.linkBlue)
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Call \(label)")
                }
            }
            .sheet(isPresented: $texting) {
                MessageComposer(recipients: [digits], body: messageBody)
                    .ignoresSafeArea()
            }
        }
    }
}

/// Centered message for an empty list.
struct EmptyNote: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 6) {
            Text(title).font(.headline).foregroundColor(Brand.navy)
            Text(detail).font(.subheadline).foregroundColor(Brand.muted).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }
}

func tripStatusColor(_ status: String) -> Color {
    switch status {
    case "IN_TRANSIT": return Brand.linkBlue
    case "DROPPED_OFF", "COMPLETED": return Brand.ok
    case "CANCELLED", "EXCEPTION": return Brand.danger
    case "DRAFT": return Brand.muted
    default: return Color.orange
    }
}

/// The top of an equipment page: the marking, big and bold the way it is
/// painted on the steel, with what kind of unit it is and where it stands.
/// Tap the number to copy it; long-press for the owner block or the serial.
struct EquipmentHero: View {
    let kind: CopyPart.Kind
    let number: String
    var status: String? = nil
    var statusColor: Color = Brand.sky
    /// Short facts under the number, such as line, size and cargo.
    var tags: [String] = []

    private var kindLabel: String { kind == .chassis ? "CHASSIS" : "CONTAINER" }

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: kind == .chassis ? "truck.box" : "shippingbox.fill")
                Text(kindLabel).tracking(1.2)
            }
            .font(.caption.weight(.bold))
            .foregroundColor(Color.white.opacity(0.75))

            marking
                .copyable(number, label: kind == .chassis ? "Chassis" : "Container", kind: kind)

            if let status {
                HStack(spacing: 6) {
                    Circle().fill(statusColor).frame(width: 7, height: 7)
                    Text(status)
                }
                .font(.subheadline.weight(.bold))
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.white.opacity(0.14)))
            }

            if !tags.isEmpty {
                HStack(spacing: 8) {
                    ForEach(tags, id: \.self) { tag in
                        Text(tag)
                            .font(.footnote.weight(.semibold))
                            .foregroundColor(Brand.navy)
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Brand.skyWash))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .padding(.horizontal, 16)
        .background(
            LinearGradient(colors: [Brand.navy, Brand.navyDeep], startPoint: .top, endPoint: .bottom)
        )
        .clipShape(RoundedRectangle(cornerRadius: Brand.radius, style: .continuous))
        .shadow(color: Brand.navy.opacity(0.25), radius: 12, x: 0, y: 4)
    }

    /// Owner block, serial, and the check digit in its own box, as stencilled
    /// on a container. A chassis is letters then digits.
    @ViewBuilder
    private var marking: some View {
        let compact = kind == .chassis ? Marking.maskChassis(number) : Marking.maskContainer(number)
        let letters = String(compact.prefix(while: { $0.isLetter }))
        let rest = String(compact.dropFirst(letters.count))
        HStack(alignment: .center, spacing: 10) {
            if kind == .container, compact.count == 11 {
                Text(letters)
                Text(String(rest.prefix(6)))
                Text(String(rest.suffix(1)))
                    .padding(.horizontal, 6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.85), lineWidth: 2))
            } else if !letters.isEmpty, !rest.isEmpty {
                Text(letters)
                Text(rest)
            } else {
                Text(number)
            }
        }
        .font(.system(size: 38, weight: .heavy, design: .monospaced))
        .foregroundColor(.white)
        .lineLimit(1)
        .minimumScaleFactor(0.5)
    }
}

/// Facts about a unit as an even grid: a small label over a bold value.
/// Facts with no value are left out.
struct FactGrid: View {
    struct Fact: Identifiable {
        let label: String
        let value: String?
        /// Opens that unit's page when tapped, instead of copying.
        var route: EquipmentRoute? = nil
        var id: String { label }
    }

    let facts: [Fact]

    private var shown: [Fact] { facts.filter { !($0.value ?? "").isEmpty } }

    var body: some View {
        if !shown.isEmpty {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], alignment: .leading, spacing: 16) {
                ForEach(shown) { fact in
                    if let route = fact.route {
                        NavigationLink(value: route) { cell(fact, linked: true) }
                            .buttonStyle(.plain)
                    } else {
                        cell(fact, linked: false).copyable(fact.value)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
        }
    }

    private func cell(_ fact: Fact, linked: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(fact.label.uppercased())
                .font(.caption2.weight(.bold))
                .tracking(0.6)
                .foregroundColor(Brand.muted)
            HStack(spacing: 4) {
                Text(fact.value ?? "")
                    .font(.body.weight(.semibold))
                    .foregroundColor(linked ? Brand.linkBlue : Brand.navy)
                    .lineLimit(2)
                if linked {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundColor(Brand.linkBlue)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// One of a row of even action tiles: icon over a word.
struct ActionTile: View {
    let title: String
    let symbol: String
    var primary = false

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .frame(height: 22)
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundColor(primary ? .white : Brand.navy)
        .frame(maxWidth: .infinity, minHeight: 68)
        .background(primary ? Brand.linkBlue : Brand.paper)
        .clipShape(RoundedRectangle(cornerRadius: Brand.controlRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Brand.controlRadius, style: .continuous).stroke(primary ? Color.clear : Brand.line))
        .shadow(color: Brand.navy.opacity(primary ? 0.18 : 0.06), radius: 6, x: 0, y: 2)
        .contentShape(Rectangle())
    }
}
