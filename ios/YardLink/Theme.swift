import SwiftUI

/// Yard Link brand kit: Yard Navy, Link Blue, Container Sky, Paper, Mist.
/// Navy on white for running text; blue is the accent. The same palette and
/// the same shapes as the web app, so the two feel like one product.
enum Brand {
    static let navy = Color(red: 0x05 / 255, green: 0x25 / 255, blue: 0x43 / 255)
    static let navyDeep = Color(red: 0x03 / 255, green: 0x1A / 255, blue: 0x30 / 255)
    static let linkBlue = Color(red: 0x00 / 255, green: 0x7D / 255, blue: 0xE0 / 255)
    static let sky = Color(red: 0x5D / 255, green: 0xAE / 255, blue: 0xFE / 255)
    static let skyWash = Color(red: 0xEE / 255, green: 0xF7 / 255, blue: 0xFF / 255)
    static let mist = Color(red: 0xF2 / 255, green: 0xF7 / 255, blue: 0xFA / 255)
    static let paper = Color.white
    static let line = Color(red: 0xE0 / 255, green: 0xE6 / 255, blue: 0xEA / 255)
    static let ink = Color(red: 0x39 / 255, green: 0x46 / 255, blue: 0x4F / 255)
    static let muted = Color(red: 0x5F / 255, green: 0x6C / 255, blue: 0x75 / 255)
    static let danger = Color(red: 0xB2 / 255, green: 0x3A / 255, blue: 0x30 / 255)
    static let ok = Color(red: 0x1D / 255, green: 0x7A / 255, blue: 0x4C / 255)
    static let warn = Color(red: 0xAE / 255, green: 0x58 / 255, blue: 0x08 / 255)

    static let radius: CGFloat = 16
    static let controlRadius: CGFloat = 12
}

// MARK: - Surfaces

extension View {
    /// The lifted white surface every card sits on.
    func cardSurface(radius: CGFloat = Brand.radius) -> some View {
        self
            .background(Brand.paper)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(Brand.line))
            .shadow(color: Brand.navy.opacity(0.07), radius: 8, x: 0, y: 2)
    }

    /// Mist page background with a faint blue glow at the top, as on the web.
    func screenBackground() -> some View {
        background(
            ZStack(alignment: .top) {
                Brand.mist
                LinearGradient(colors: [Brand.linkBlue.opacity(0.08), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 220)
            }
            .ignoresSafeArea()
        )
    }

    /// Inner screens: a white bar with a blue Back link and a navy title, as
    /// the web app's wizard header. Root screens hide the bar and use
    /// BrandStrip instead.
    func lightBar() -> some View {
        self
            .toolbarBackground(Brand.paper, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.light, for: .navigationBar)
    }
}

/// "YARD LINK" as it appears in the web app's brand bar.
struct BrandMark: View {
    var body: some View {
        HStack(spacing: 5) {
            Text("YARD").foregroundColor(.white)
            Text("LINK").foregroundColor(Brand.sky)
        }
        .font(.system(size: 16, weight: .heavy))
        .tracking(1.4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Yard Link")
    }
}

/// The slim navy strip across the top of every root screen: the brand in the
/// middle, room for one control on the right (Messages on Home).
struct BrandStrip<Trailing: View>: View {
    @ViewBuilder var trailing: Trailing

    init(@ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.trailing = trailing()
    }

    var body: some View {
        ZStack {
            BrandMark()
            HStack {
                Spacer()
                trailing
            }
            .padding(.trailing, 6)
        }
        .frame(height: 52)
        .frame(maxWidth: .infinity)
        .background(Brand.navy.ignoresSafeArea(edges: .top))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
        }
    }
}

extension View {
    /// A root screen: the brand strip pinned to the top in place of the
    /// system bar, with the content scrolling beneath it.
    func brandScreen<Trailing: View>(@ViewBuilder trailing: () -> Trailing = { EmptyView() }) -> some View {
        self
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) { BrandStrip(trailing: trailing) }
    }
}

/// The large heading at the top of a root screen's content, as on the web.
struct PageTitle: View {
    let text: String
    var alignment: Alignment = .leading

    var body: some View {
        Text(text)
            .font(.system(size: 28, weight: .bold))
            .tracking(-0.4)
            .foregroundColor(Brand.navy)
            .multilineTextAlignment(alignment == .center ? .center : .leading)
            .frame(maxWidth: .infinity, alignment: alignment)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A page heading with its own controls on the right, as the web app's title
/// row. The system bar is hidden on root screens, so a screen's actions live
/// here beside the title.
struct PageHeader<Actions: View>: View {
    let title: String
    @ViewBuilder var actions: Actions

    init(_ title: String, @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.title = title
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            PageTitle(text: title)
            actions
        }
    }
}

/// The square, quiet control used beside a page heading.
struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 18, weight: .semibold))
            .foregroundColor(Brand.navy)
            .frame(width: 44, height: 44)
            .background(configuration.isPressed ? Brand.line.opacity(0.6) : Brand.paper)
            .clipShape(RoundedRectangle(cornerRadius: Brand.controlRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Brand.controlRadius, style: .continuous).stroke(Brand.line))
    }
}

/// White card on the mist background — the basic surface of the app.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
    }
}

// MARK: - Buttons

/// Full-width primary action, sized for a gloved thumb.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 54)
            .foregroundColor(.white)
            .background(Brand.linkBlue.opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.38))
            .clipShape(RoundedRectangle(cornerRadius: Brand.controlRadius, style: .continuous))
            .shadow(color: Brand.linkBlue.opacity(isEnabled ? 0.28 : 0), radius: 8, x: 0, y: 4)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}

/// Solid navy action, second in weight to the primary one.
struct DarkButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 54)
            .foregroundColor(.white)
            .background(Brand.navy.opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.4))
            .clipShape(RoundedRectangle(cornerRadius: Brand.controlRadius, style: .continuous))
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 52)
            .foregroundColor(Brand.navy.opacity(isEnabled ? 1 : 0.45))
            .background(Brand.paper.opacity(configuration.isPressed ? 0.6 : 1))
            .overlay(RoundedRectangle(cornerRadius: Brand.controlRadius, style: .continuous).stroke(Brand.line))
            .clipShape(RoundedRectangle(cornerRadius: Brand.controlRadius, style: .continuous))
    }
}

/// Quiet, full-width destructive action such as Cancel Trip.
struct DangerTextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 48)
            .foregroundColor(Brand.danger.opacity(configuration.isPressed ? 0.6 : 1))
    }
}

// MARK: - Messages and status

/// A notice across the page: something went wrong, needs care, or went well.
struct Banner: View {
    enum Kind {
        case error, warning, info, success

        var color: Color {
            switch self {
            case .error: return Brand.danger
            case .warning: return Brand.warn
            case .info: return Brand.linkBlue
            case .success: return Brand.ok
            }
        }

        var symbol: String {
            switch self {
            case .error: return "exclamationmark.octagon.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .info: return "info.circle.fill"
            case .success: return "checkmark.circle.fill"
            }
        }
    }

    let kind: Kind
    var title: String?
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: kind.symbol)
                .foregroundColor(kind.color)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                if let title {
                    Text(title).font(.subheadline.weight(.bold))
                }
                Text(message).font(.subheadline)
            }
            .foregroundColor(Brand.navy)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(kind.color.opacity(0.1))
        .overlay(RoundedRectangle(cornerRadius: Brand.controlRadius, style: .continuous).stroke(kind.color.opacity(0.35)))
        .clipShape(RoundedRectangle(cornerRadius: Brand.controlRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

struct ErrorBanner: View {
    let message: String

    var body: some View {
        Banner(kind: .error, message: message)
    }
}

struct StatusPill: View {
    let text: String
    var color: Color = Brand.linkBlue

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
        }
        .font(.caption.weight(.bold))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .foregroundColor(color)
        .background(color.opacity(0.12))
        .clipShape(Capsule())
    }
}

// MARK: - Rows and fields

/// A large row that is the answer to a question: tap it and move on.
struct OptionRow: View {
    let symbol: String
    let title: String
    var detail: String?
    var trailing: String?
    var selected = false
    var tint: Color = Brand.linkBlue
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(tint)
                    .frame(width: 42, height: 42)
                    .background(tint.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .foregroundColor(Brand.navy)
                        .multilineTextAlignment(.leading)
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(.footnote)
                            .foregroundColor(Brand.muted)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing)
                        .font(.caption.weight(.bold))
                        .foregroundColor(Brand.muted)
                }
                Image(systemName: selected ? "checkmark.circle.fill" : "chevron.right")
                    .font(.system(size: selected ? 20 : 14, weight: .semibold))
                    .foregroundColor(selected ? Brand.linkBlue : Brand.muted.opacity(0.6))
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
            .background(Brand.paper)
            .clipShape(RoundedRectangle(cornerRadius: Brand.radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Brand.radius, style: .continuous)
                    .stroke(selected ? Brand.linkBlue : Brand.line, lineWidth: selected ? 2 : 1)
            )
            .shadow(color: Brand.navy.opacity(0.05), radius: 6, x: 0, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Search box used above every pick list.
struct SearchField: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundColor(Brand.muted)
            TextField(prompt, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(Brand.muted)
                }
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 48)
        .background(Brand.paper)
        .clipShape(RoundedRectangle(cornerRadius: Brand.controlRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Brand.controlRadius, style: .continuous).stroke(Brand.line))
    }
}

/// Field label above a control.
struct FieldLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundColor(Brand.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The standard text box: white, lined, 12-point corners.
struct FieldBox<Content: View>: View {
    var problem = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, 12)
            .frame(minHeight: 50)
            .background(Brand.paper)
            .clipShape(RoundedRectangle(cornerRadius: Brand.controlRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Brand.controlRadius, style: .continuous)
                    .stroke(problem ? Brand.danger : Brand.line, lineWidth: problem ? 2 : 1)
            )
    }
}

/// Two or three equal choices on one line, e.g. Empty or Load.
struct SegmentChoice<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    let selected: Value?
    let onSelect: (Value) -> Void

    var body: some View {
        HStack(spacing: 10) {
            ForEach(options, id: \.value) { option in
                let isOn = selected == option.value
                Button {
                    onSelect(option.value)
                } label: {
                    Text(option.label)
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .foregroundColor(isOn ? .white : Brand.navy)
                        .background(isOn ? Brand.navy : Brand.paper)
                        .clipShape(RoundedRectangle(cornerRadius: Brand.controlRadius, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: Brand.controlRadius, style: .continuous)
                                .stroke(isOn ? Brand.navy : Brand.line)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
    }
}

/// Small uppercase caption over a value, as on the trip card.
struct FactCell: View {
    let label: String
    let value: String
    var mono = false
    var alignment: HorizontalAlignment = .leading
    /// Off inside a button, where the tap belongs to the button.
    var copyOnTap = true
    var copyKind: CopyPart.Kind = .plain

    var body: some View {
        VStack(alignment: alignment, spacing: 3) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(0.7)
                .foregroundColor(Brand.muted.opacity(0.85))
            Text(value)
                .font(mono ? .system(.subheadline, design: .monospaced).weight(.bold) : .subheadline.weight(.bold))
                .foregroundColor(Brand.navy)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .copyable(mono ? value : nil, label: label, onTap: copyOnTap, kind: copyKind)
        }
        .frame(maxWidth: .infinity, alignment: alignment == .trailing ? .trailing : .leading)
        .accessibilityElement(children: .combine)
    }
}

/// The action that stays at the bottom of a step.
struct BottomBar<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 10) { content }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial)
            .overlay(alignment: .top) { Divider() }
    }
}
