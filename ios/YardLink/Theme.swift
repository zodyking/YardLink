import SwiftUI

/// Yard Link brand kit: Yard Navy, Link Blue, Container Sky, Paper, Mist.
/// Navy on white for running text; blue is the accent.
enum Brand {
    static let navy = Color(red: 0x05 / 255, green: 0x25 / 255, blue: 0x43 / 255)
    static let linkBlue = Color(red: 0x00 / 255, green: 0x7D / 255, blue: 0xE0 / 255)
    static let sky = Color(red: 0x5D / 255, green: 0xAE / 255, blue: 0xFE / 255)
    static let mist = Color(red: 0xF2 / 255, green: 0xF7 / 255, blue: 0xFA / 255)
    static let paper = Color.white
    static let line = Color(red: 0xE0 / 255, green: 0xE6 / 255, blue: 0xEA / 255)
    static let muted = Color(red: 0x5F / 255, green: 0x6C / 255, blue: 0x75 / 255)
    static let danger = Color(red: 0xB2 / 255, green: 0x3A / 255, blue: 0x30 / 255)
    static let ok = Color(red: 0x1D / 255, green: 0x7A / 255, blue: 0x4C / 255)
}

/// Full-width primary action, sized for a gloved thumb.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 52)
            .foregroundColor(.white)
            .background(Brand.linkBlue.opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 52)
            .foregroundColor(Brand.navy)
            .background(Brand.mist.opacity(configuration.isPressed ? 0.6 : 1))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Brand.line))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// White card on the mist background — the basic surface of the app.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.paper)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Brand.line))
    }
}

struct ErrorBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message).font(.subheadline)
            Spacer(minLength: 0)
        }
        .foregroundColor(Brand.danger)
        .padding(12)
        .background(Brand.danger.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

struct StatusPill: View {
    let text: String
    var color: Color = Brand.linkBlue

    var body: some View {
        Text(text)
            .font(.caption.weight(.bold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .foregroundColor(color)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }
}
