import SwiftUI
import UIKit

/// Tap any number — container, chassis, booking, seal, phone, join code — and
/// it goes to the clipboard, the way the old app worked. The confirmation is
/// shown in its own window so it is visible over sheets and covers too.
enum CopyBoard {
    static func copy(_ value: String?, label: String? = nil) {
        guard let text = usable(value) else { return }
        UIPasteboard.general.string = text
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        CopyToast.show(label.map { "\($0) copied" } ?? "Copied \(text)")
    }

    /// Placeholders and blanks are not worth copying.
    static func usable(_ value: String?) -> String? {
        let text = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || text == "—" || text == "-" { return nil }
        return text
    }
}

/// A pill that fades in at the bottom of the screen and leaves on its own.
enum CopyToast {
    private static var window: UIWindow?
    private static var dismissal: DispatchWorkItem?

    static func show(_ message: String) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return }

        dismissal?.cancel()
        let host = window ?? makeWindow(in: scene)
        window = host
        guard let pill = host.rootViewController?.view.subviews.first as? UILabel else { return }

        pill.text = "  \(message)  "
        host.isHidden = false
        UIView.animate(withDuration: 0.16) { pill.alpha = 1 }

        let work = DispatchWorkItem {
            UIView.animate(withDuration: 0.22, animations: { pill.alpha = 0 }) { _ in
                guard pill.alpha == 0 else { return }
                window?.isHidden = true
                window = nil
            }
        }
        dismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }

    private static func makeWindow(in scene: UIWindowScene) -> UIWindow {
        let host = PassthroughWindow(windowScene: scene)
        host.windowLevel = .alert
        host.backgroundColor = .clear

        let controller = UIViewController()
        controller.view.backgroundColor = .clear
        controller.view.isUserInteractionEnabled = false

        let pill = UILabel()
        pill.alpha = 0
        pill.font = .systemFont(ofSize: 14, weight: .semibold)
        pill.textColor = .white
        pill.textAlignment = .center
        pill.backgroundColor = UIColor(Brand.navy).withAlphaComponent(0.94)
        pill.layer.cornerRadius = 18
        pill.layer.masksToBounds = true
        pill.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(pill)

        NSLayoutConstraint.activate([
            pill.centerXAnchor.constraint(equalTo: controller.view.centerXAnchor),
            pill.bottomAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.bottomAnchor, constant: -28),
            pill.heightAnchor.constraint(equalToConstant: 36),
            pill.leadingAnchor.constraint(greaterThanOrEqualTo: controller.view.leadingAnchor, constant: 24),
            pill.trailingAnchor.constraint(lessThanOrEqualTo: controller.view.trailingAnchor, constant: -24),
        ])

        host.rootViewController = controller
        return host
    }
}

/// Taps fall through to the app underneath.
private final class PassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}

/// The same pieces the web app offers when a marking is tapped: the whole
/// number, the owner block, and the serial.
struct CopyPart: Identifiable {
    enum Kind { case container, chassis, seal, plain }

    let id: String
    let label: String
    let value: String

    static func parts(of kind: Kind, from raw: String) -> [CopyPart] {
        switch kind {
        case .container:
            let compact = Marking.maskContainer(raw)
            guard !compact.isEmpty else { return [] }
            let letters = compact.filter { $0.isLetter }
            let digits = compact.dropFirst(letters.count)
            return unique([
                CopyPart(id: "full", label: "Full", value: Marking.formatContainer(compact)),
                CopyPart(id: "bic", label: "BIC", value: letters),
                CopyPart(id: "serial", label: "Serial", value: String(digits.prefix(6))),
            ])
        case .chassis:
            let compact = Marking.maskChassis(raw)
            guard !compact.isEmpty else { return [] }
            let letters = compact.filter { $0.isLetter }
            return unique([
                CopyPart(id: "full", label: "Full", value: compact),
                CopyPart(id: "bic", label: "BIC", value: letters),
                CopyPart(id: "serial", label: "Serial", value: String(compact.dropFirst(letters.count))),
            ])
        case .seal:
            return unique([
                CopyPart(id: "full", label: "Full", value: raw),
                CopyPart(id: "letters", label: "Letters", value: raw.uppercased().filter { $0.isLetter }),
                CopyPart(id: "digits", label: "Digits", value: raw.filter { $0.isNumber }),
            ])
        case .plain:
            return [CopyPart(id: "full", label: "Full", value: raw)]
        }
    }

    private static func unique(_ parts: [CopyPart]) -> [CopyPart] {
        var seen = Set<String>()
        return parts.filter { part in
            guard !part.value.isEmpty, !seen.contains(part.value) else { return false }
            seen.insert(part.value)
            return true
        }
    }
}

private struct Copyable: ViewModifier {
    let value: String?
    let label: String?
    let onTap: Bool
    let kind: CopyPart.Kind

    func body(content: Content) -> some View {
        guard let text = CopyBoard.usable(value) else { return AnyView(content) }
        let parts = CopyPart.parts(of: kind, from: text)
        let menu = content
            .contextMenu {
                if parts.count > 1 {
                    ForEach(parts) { part in
                        Button {
                            CopyBoard.copy(part.value, label: part.id == "full" ? label : part.label)
                        } label: {
                            Label("Copy \(part.label.lowercased()) — \(part.value)", systemImage: "doc.on.doc")
                        }
                    }
                } else {
                    Button {
                        CopyBoard.copy(text, label: label)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                }
            }
            .accessibilityAction(named: "Copy") { CopyBoard.copy(text, label: label) }
        guard onTap else { return AnyView(menu) }
        return AnyView(
            menu
                .contentShape(Rectangle())
                .onTapGesture { CopyBoard.copy(text, label: label) }
        )
    }
}

extension View {
    /// Tap to copy this value; long-press for the same thing from a menu.
    /// Inside a row that opens something, pass `onTap: false` so the tap is
    /// left to the row and only the long-press copies. A marking kind puts the
    /// owner block and the serial in the long-press menu, as the web app does.
    func copyable(
        _ value: String?,
        label: String? = nil,
        onTap: Bool = true,
        kind: CopyPart.Kind = .plain
    ) -> some View {
        modifier(Copyable(value: value, label: label, onTap: onTap, kind: kind))
    }
}
