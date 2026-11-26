import SwiftUI
import WebKit

/// Check containers on ShipCSX, with the typing done for you.
///
/// This is the real ShipCSX page in a browser the driver can see and use.
/// They pass ShipCSX's own "verify you are human" check and tap Search;
/// the app picks the company's CSX location, types in three containers at a
/// time (the form's three rows), then reads the results page and saves each
/// container's status. Every loaded container and every container at a
/// customer is covered, so one run brings them all up to date.
struct ShipcsxCheckView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    /// The container Check CSX was opened from; it goes in the first search.
    let firstContainerId: String?
    /// Called after results are saved, so the screen underneath can refresh.
    var onSaved: () -> Void = {}

    struct Box: Decodable, Hashable {
        let containerId: String
        let number: String
    }

    struct Saved: Decodable, Hashable, Identifiable {
        let containerId: String
        let number: String
        let status: String
        var id: String { containerId }
    }

    private struct Plan: Decodable {
        let terminal: String
        let reference: String
        let boxes: [Box]
    }

    private struct SavedPayload: Decodable { let results: [Saved] }

    private struct ResultsBody: Encodable {
        let terminal: String
        let containerIds: [String]
        let pageText: String
    }

    @State private var page = ShipcsxPage()
    @State private var plan: Plan?
    @State private var loadError: String?
    @State private var batchIndex = 0
    @State private var filled = false
    @State private var fillTries = 0
    @State private var working = false
    @State private var batchSaved = false
    @State private var saved: [Saved] = []
    @State private var note: String?

    private static let rowsPerSearch = 3

    private var batches: [[Box]] {
        guard let plan else { return [] }
        return stride(from: 0, to: plan.boxes.count, by: Self.rowsPerSearch).map {
            Array(plan.boxes[$0 ..< min($0 + Self.rowsPerSearch, plan.boxes.count)])
        }
    }

    private var batch: [Box] { batchIndex < batches.count ? batches[batchIndex] : [] }
    private var isLastBatch: Bool { batchIndex >= batches.count - 1 }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let loadError {
                    ErrorBanner(message: loadError).padding()
                    Spacer()
                } else if let plan, plan.boxes.isEmpty {
                    Text("No loaded containers or containers at customers to check.")
                        .font(.subheadline)
                        .foregroundColor(Brand.muted)
                        .padding()
                    Spacer()
                } else if plan != nil {
                    ShipcsxWebView(page: page, url: ShipcsxPage.lookupURL)
                    panel
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Check CSX")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { page.load() } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Reload ShipCSX")
                        .disabled(plan == nil)
                }
            }
            .task { await loadPlan() }
            .task(id: plan == nil) { await watch() }
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(batches.count > 1 ? "Search \(batchIndex + 1) of \(batches.count)" : "Search")
                    .font(.caption.weight(.bold))
                    .foregroundColor(Brand.muted)
                Spacer()
                Text(plan?.terminal ?? "")
                    .font(.caption.weight(.bold))
                    .foregroundColor(Brand.muted)
            }
            Text(batch.map { Marking.formatContainer($0.number) }.joined(separator: "  ·  "))
                .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                .foregroundColor(Brand.navy)
            Text(note ?? "If ShipCSX asks, tick \"Verify you are human\". The containers fill in once the form shows.")
                .font(.footnote)
                .foregroundColor(Brand.muted)
                .fixedSize(horizontal: false, vertical: true)
            if batchSaved {
                ForEach(saved.suffix(batch.count)) { row in
                    HStack {
                        Text(Marking.formatContainer(row.number))
                            .font(.system(.footnote, design: .monospaced))
                        Spacer()
                        Text(row.status).font(.footnote.weight(.semibold))
                    }
                    .foregroundColor(Brand.navy)
                }
                if isLastBatch {
                    Button("Done") { dismiss() }
                        .buttonStyle(PrimaryButtonStyle())
                } else {
                    Button("Next \(batches[batchIndex + 1].count) Containers") { nextBatch() }
                        .buttonStyle(PrimaryButtonStyle())
                }
            } else if fillTries >= 8 && !filled {
                Button("Fill Containers") { Task { await fill() } }
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(14)
        .background(Brand.paper.ignoresSafeArea(edges: .bottom))
    }

    private func loadPlan() async {
        guard plan == nil, let api = model.api else { return }
        let query = firstContainerId.map { "?containerId=\($0)" } ?? ""
        do {
            plan = try await api.get("/api/shipcsx/plan\(query)")
        } catch {
            loadError = model.handle(error)
        }
    }

    /// Follow the page: fill the form when it shows, save the results when they do.
    private func watch() async {
        guard plan != nil else { return }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !working, !batch.isEmpty, !batchSaved else { continue }
            switch await page.state() {
            case .challenge:
                note = "Tick \"Verify you are human\" on ShipCSX."
            case .form where !filled && fillTries < 8:
                await fill()
            case .results where filled:
                await saveResults()
            default:
                break
            }
        }
    }

    private func fill() async {
        guard let plan else { return }
        working = true
        defer { working = false }
        fillTries += 1
        let outcome = await page.fill(batch.map(\.number), terminal: plan.terminal, reference: plan.reference)
        guard outcome.rows > 0 else {
            note = fillTries >= 8
                ? "Couldn't find the container boxes on this page. Tap Fill Containers to try again."
                : nil
            return
        }
        filled = true
        let place = outcome.terminalPicked ? "" : " Pick \(plan.terminal) as the location first."
        note = outcome.rows < batch.count
            ? "Filled \(outcome.rows) of \(batch.count).\(place) Tap Search on ShipCSX."
            : "Filled.\(place) Tap Search on ShipCSX."
    }

    private func saveResults() async {
        guard let plan, let api = model.api else { return }
        working = true
        defer { working = false }
        note = "Saving what ShipCSX shows…"
        let text = await page.text()
        do {
            let payload: SavedPayload = try await api.post(
                "/api/shipcsx/results",
                body: ResultsBody(terminal: plan.terminal, containerIds: batch.map(\.containerId), pageText: text)
            )
            saved += payload.results
            batchSaved = true
            note = isLastBatch
                ? "All \(plan.boxes.count) checked and saved."
                : "Saved. \(plan.boxes.count - saved.count) left to check."
            onSaved()
        } catch {
            note = model.handle(error)
        }
    }

    private func nextBatch() {
        batchIndex += 1
        filled = false
        fillTries = 0
        batchSaved = false
        note = nil
        page.load()
    }
}

/// The ShipCSX page the driver is looking at, for reading and filling it.
@MainActor
final class ShipcsxPage {
    static let lookupURL = URL(string: "https://next.shipcsx.com/#/shipment/lookup")!

    enum State: String { case form, results, challenge, other }

    struct FillOutcome {
        let rows: Int
        let terminalPicked: Bool
    }

    fileprivate weak var webView: WKWebView?

    func load() {
        webView?.load(URLRequest(url: Self.lookupURL))
    }

    func state() async -> State {
        guard let webView,
              let raw = try? await webView.evaluateJavaScript(Self.stateScript) as? String else { return .other }
        return State(rawValue: raw) ?? .other
    }

    func text() async -> String {
        guard let webView else { return "" }
        return (try? await webView.evaluateJavaScript("document.body ? document.body.innerText : ''") as? String) ?? ""
    }

    /// Picks the CSX location and types each container ("TTRU 485022", the
    /// form's own example format) into the next row, with the reference.
    /// Nothing is submitted: the driver taps Search.
    func fill(_ containers: [String], terminal: String, reference: String) async -> FillOutcome {
        guard let webView else { return FillOutcome(rows: 0, terminalPicked: false) }
        let equipment = containers.compactMap { number -> String? in
            let compact = Marking.normalize(number)
            guard compact.count >= 10 else { return nil }
            return "\(compact.prefix(4)) \(compact.dropFirst(4).prefix(6))"
        }
        let result = try? await webView.callAsyncJavaScript(
            Self.fillScript,
            arguments: ["equipment": equipment, "terminal": terminal, "reference": reference],
            in: nil,
            in: .page
        )
        let values = result as? [String: Any]
        return FillOutcome(
            rows: (values?["rows"] as? NSNumber)?.intValue ?? 0,
            terminalPicked: (values?["terminal"] as? Bool) ?? false
        )
    }

    private static let stateScript = """
    (() => {
      const text = (document.body ? document.body.innerText : '') + ' ' + document.title;
      if (/shipment lookup results|(NOTIFIED|ENROUTE|IN-GATE|OTHERS)\\s*\\(\\d+\\)/i.test(text)) return 'results';
      if (/verify you are human|performing security verification|just a moment/i.test(text)) return 'challenge';
      if (/equipment\\s*#/i.test(text) && document.querySelector('input')) return 'form';
      return 'other';
    })()
    """

    private static let fillScript = """
    const sleep = (ms) => new Promise((done) => setTimeout(done, ms));
    const visible = (el) => !!el && el.getClientRects().length > 0 && getComputedStyle(el).visibility !== 'hidden';
    const norm = (text) => (text || '').replace(/\\s+/g, ' ').trim().toLowerCase();
    const type = (el, value) => {
      const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
      el.focus();
      Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, value);
      el.dispatchEvent(new Event('input', { bubbles: true }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
      el.dispatchEvent(new KeyboardEvent('keyup', { bubbles: true }));
      el.blur();
    };

    // The CSX location.
    const wanted = norm(terminal);
    let picked = false;
    const select = [...document.querySelectorAll('select')].find(visible);
    if (select) {
      const option = [...select.options].find((o) => norm(o.textContent) === wanted);
      if (option) {
        if (select.value !== option.value) {
          select.value = option.value;
          select.dispatchEvent(new Event('change', { bubbles: true }));
        }
        picked = true;
      }
    } else {
      const trigger = [...document.querySelectorAll('ion-select, mat-select, ng-select, p-dropdown, [role="combobox"], [aria-haspopup="listbox"]')].find(visible);
      if (trigger && norm(trigger.innerText || trigger.getAttribute('value')) === wanted) {
        picked = true;
      } else if (trigger) {
        trigger.click();
        await sleep(600);
        const options = [...document.querySelectorAll('[role="option"], [role="radio"], ion-select-option, mat-option, .alert-radio-button, ion-item, li')].filter(visible);
        const match = options.find((o) => norm(o.innerText) === wanted);
        if (match) {
          match.click();
          await sleep(300);
          const ok = [...document.querySelectorAll('.alert-button, button')].filter(visible)
            .find((b) => /^(ok|done|select)$/i.test((b.innerText || '').trim()));
          if (ok) { ok.click(); await sleep(300); }
          picked = true;
        } else {
          document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
        }
      }
    }

    // The rows: an equipment box on the left, a reference box on the right.
    const inputs = [...document.querySelectorAll('input, textarea')].filter((el) =>
      visible(el) && !el.readOnly && !el.disabled && !/^(hidden|checkbox|radio|submit|button|search)$/i.test(el.type || ''));
    const groups = [];
    for (const el of inputs) {
      const box = el.getBoundingClientRect();
      const group = groups.find((g) => Math.abs(g.top - box.top) < 8);
      if (group) group.items.push({ el, left: box.left });
      else groups.push({ top: box.top, items: [{ el, left: box.left }] });
    }
    const rows = groups
      .filter((g) => g.items.length === 2)
      .sort((a, b) => a.top - b.top)
      .map((g) => g.items.sort((a, b) => a.left - b.left).map((item) => item.el));

    let filled = 0;
    rows.forEach((row, i) => {
      const [equipmentBox, referenceBox] = row;
      if (i < equipment.length) {
        type(equipmentBox, equipment[i]);
        if (!referenceBox.value) type(referenceBox, reference);
        filled++;
      } else if (equipmentBox.value) {
        type(equipmentBox, '');
        type(referenceBox, '');
      }
    });
    return { rows: filled, terminal: picked };
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
