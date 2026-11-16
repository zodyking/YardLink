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
}

/// Label on the left, value on the right; hidden when there is no value.
struct InfoRow: View {
    let label: String
    let value: String?

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

    var body: some View {
        Text(text)
            .font(font.weight(.bold))
            .foregroundColor(Brand.navy)
            .textSelection(.enabled)
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
                    Text(number).font(.subheadline.weight(.semibold)).foregroundColor(Brand.navy)
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
