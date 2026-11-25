import SwiftUI
import UIKit
import WebKit

/// Check containers on ShipCSX by hand, with the typing done for you.
///
/// This is the real ShipCSX page in a browser the driver works: they pass
/// ShipCSX's own "verify you are human" check, pick the CSX location and tap
/// Search. The app only fills the container's initial and number into the
/// form when the driver taps Fill, the way a password manager fills a login.
struct ShipcsxCheckView: View {
    @Environment(\.dismiss) private var dismiss
    let containerNumbers: [String]
    /// The CSX location to pick, when the container's site says.
    let terminalHint: String?

    @State private var page = ShipcsxPage()
    @State private var note: String?

    private static let lookupURL = URL(string: "https://next.shipcsx.com/#/shipment/lookup")!

    private var fillTitle: String {
        containerNumbers.count == 1
            ? "Fill \(Marking.formatContainer(containerNumbers[0]))"
            : "Fill \(containerNumbers.count) containers"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ShipcsxWebView(page: page, url: Self.lookupURL)
                VStack(alignment: .leading, spacing: 10) {
                    Text(note ?? instructions)
                        .font(.footnote)
                        .foregroundColor(Brand.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(fillTitle) { Task { await fill() } }
                        .buttonStyle(PrimaryButtonStyle())
                }
                .padding(14)
                .background(Brand.paper.ignoresSafeArea(edges: .bottom))
            }
            .navigationTitle("ShipCSX")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { page.reload() } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Reload ShipCSX")
                }
            }
        }
    }

    private var instructions: String {
        let pick = terminalHint.map { "pick \($0)" } ?? "pick the CSX location"
        return "If ShipCSX asks, tick \"Verify you are human\". Then \(pick), tap Fill, and tap Search on ShipCSX."
    }

    private func fill() async {
        let filled = await page.fill(containerNumbers)
        if filled == 0 {
            UIPasteboard.general.string = containerNumbers.map { Marking.formatContainer($0) }.joined(separator: "\n")
            note = "Couldn't find the container boxes on this page yet. The number is copied, so you can paste it."
        } else if filled < containerNumbers.count {
            note = "Filled \(filled) of \(containerNumbers.count). Add rows on ShipCSX, then tap Fill again for the rest."
        } else {
            note = "Filled. Check the location, then tap Search on ShipCSX."
        }
    }
}

/// The page the driver is looking at, so the Fill button can type into it.
@MainActor
final class ShipcsxPage {
    fileprivate weak var webView: WKWebView?

    func reload() { webView?.reload() }

    /// Types each container's initial and number into the next empty row of
    /// ShipCSX's lookup form and answers how many went in. Nothing is clicked.
    func fill(_ containers: [String]) async -> Int {
        guard let webView else { return 0 }
        let rows = containers.compactMap(Self.parts)
        guard !rows.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: rows),
              let json = String(data: data, encoding: .utf8) else { return 0 }
        let result = try? await webView.evaluateJavaScript("(\(Self.fillScript))(\(json))")
        return (result as? NSNumber)?.intValue ?? 0
    }

    /// ShipCSX asks for the 4-letter initial and the 6-digit number, no check digit.
    private static func parts(_ container: String) -> [String: String]? {
        let compact = Marking.normalize(container)
        guard compact.count >= 10,
              compact.prefix(4).allSatisfy(\.isLetter),
              compact.dropFirst(4).prefix(6).allSatisfy(\.isNumber) else { return nil }
        return ["initial": String(compact.prefix(4)), "number": String(compact.dropFirst(4).prefix(6))]
    }

    /// Fills rows the way typing would: sets each box's value and fires the
    /// input events the page listens for. The reference box gets 0000 only
    /// when it's empty, as ShipCSX expects for a lookup without one.
    private static let fillScript = """
    function (rows) {
      const visible = (el) => !!(el && (el.offsetParent || el.getClientRects().length));
      const field = (el) => (el && el.tagName === 'ION-INPUT' ? el.querySelector('input') : el);
      const find = (selectors) => {
        for (const selector of selectors) {
          const found = [...document.querySelectorAll(selector)].map(field).filter(visible);
          if (found.length) return found;
        }
        return [];
      };
      const type = (el, value) => {
        const setter = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(el), 'value').set;
        el.focus();
        setter.call(el, value);
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
        el.blur();
      };
      const initials = find(['input[placeholder*="CSXU" i]', 'input[aria-label*="Initial" i]', 'ion-input[placeholder*="CSXU" i]', 'ion-input[label*="Initial" i]']);
      const numbers = find(['input[placeholder*="123456"]', 'input[aria-label*="Equipment Number" i]', 'ion-input[placeholder*="123456"]', 'ion-input[label*="Number" i]']);
      const refs = find(['input[placeholder*="Pickup" i]', 'input[aria-label*="Reference" i]', 'ion-input[placeholder*="Pickup" i]', 'ion-input[label*="Reference" i]']);
      const already = new Set(initials.map((el, i) => (el.value || '') + '|' + ((numbers[i] && numbers[i].value) || '')));
      let filled = 0;
      let row = 0;
      for (const box of rows) {
        if (already.has(box.initial + '|' + box.number)) { filled++; continue; }
        while (row < initials.length && initials[row].value) row++;
        if (row >= initials.length) break;
        if (numbers[row]) {
          type(initials[row], box.initial);
          type(numbers[row], box.number);
        } else {
          type(initials[row], box.initial + box.number);
        }
        if (refs[row] && !refs[row].value) type(refs[row], '0000');
        filled++;
        row++;
      }
      return filled;
    }
    """
}

private struct ShipcsxWebView: UIViewRepresentable {
    let page: ShipcsxPage
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        // The shared store keeps ShipCSX's cookies, so the human check isn't
        // asked for again every time.
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: config)
        view.allowsBackForwardNavigationGestures = true
        page.webView = view
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        page.webView = view
    }
}
