import SwiftUI
import WebKit

/// A system-wide Check CSX, run on the real ShipCSX page.
///
/// Every loaded container and every container at a customer is queued by
/// the CSX location it came out of (Settings' location when there's no
/// history). For each check the driver passes ShipCSX's own "verify you are
/// human" check if asked and taps Search; the app selects the terminal,
/// types the containers in, reads every results tab, saves what it says to
/// each container, and loads the next check.
struct ShipcsxCheckView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    /// The container Check CSX was opened from; it leads its location's queue.
    let firstContainerId: String?
    /// Called after results are saved, so the screen underneath can refresh.
    var onSaved: () -> Void = {}

    struct Box: Decodable, Hashable {
        let containerId: String
        let number: String
    }

    struct Check: Decodable, Hashable {
        let terminal: String
        let boxes: [Box]
    }

    struct Saved: Decodable, Hashable, Identifiable {
        let containerId: String
        let number: String
        let status: String
        var id: String { containerId }
    }

    private struct Plan: Decodable {
        let total: Int
        let checks: [Check]
    }

    private struct SavedPayload: Decodable { let results: [Saved] }

    private struct ResultsBody: Encodable {
        let terminal: String
        let containerIds: [String]
        let tabs: [ShipcsxPage.ResultsTab]
    }

    @State private var page = ShipcsxPage()
    @State private var plan: Plan?
    @State private var loadError: String?
    @State private var started = false
    @State private var queue: [Check] = []
    @State private var index = 0
    /// Containers typed into the current search.
    @State private var filled: [Box] = []
    @State private var fillTries = 0
    @State private var working = false
    @State private var lastSaved: [Saved] = []
    @State private var savedCount = 0
    @State private var finished = false
    @State private var note: String?

    private var current: Check? { index < queue.count ? queue[index] : nil }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let loadError {
                    ErrorBanner(message: loadError).padding()
                    Spacer()
                } else if let plan, !started {
                    intro(plan)
                } else if started {
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
                if started && !finished {
                    ToolbarItem(placement: .primaryAction) {
                        Button { page.restart() } label: { Image(systemName: "arrow.clockwise") }
                            .accessibilityLabel("Reload ShipCSX")
                    }
                }
            }
            .task { await loadPlan() }
            .task(id: started) { await watch() }
        }
    }

    // MARK: Before the check

    private func intro(_ plan: Plan) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if plan.checks.isEmpty {
                    Text("No loaded containers or containers at customers to check.")
                        .font(.subheadline)
                        .foregroundColor(Brand.muted)
                } else {
                    Text("System-wide check")
                        .font(.title3.weight(.bold))
                        .foregroundColor(Brand.navy)
                    Text("You're about to check every container in the system on ShipCSX: \(plan.total) \(plan.total == 1 ? "container" : "containers") in \(plan.checks.count) \(plan.checks.count == 1 ? "check" : "checks").")
                        .font(.subheadline)
                        .foregroundColor(Brand.navy)
                    Card {
                        ForEach(locationCounts(plan), id: \.terminal) { line in
                            HStack {
                                Text(line.terminal).font(.subheadline.weight(.semibold))
                                Spacer()
                                Text("\(line.containers) · \(line.checks) \(line.checks == 1 ? "check" : "checks")")
                                    .font(.footnote)
                                    .foregroundColor(Brand.muted)
                            }
                            .foregroundColor(Brand.navy)
                        }
                    }
                    Text("For each check, tick \"Verify you are human\" if ShipCSX asks, then tap Search. The app fills in the containers, saves what ShipCSX shows to each one, and loads the next check.")
                        .font(.footnote)
                        .foregroundColor(Brand.muted)
                    Button("Start Check") { start(plan) }
                        .buttonStyle(PrimaryButtonStyle())
                }
            }
            .padding()
        }
    }

    private func locationCounts(_ plan: Plan) -> [(terminal: String, containers: Int, checks: Int)] {
        var order: [String] = []
        var containers: [String: Int] = [:]
        var checks: [String: Int] = [:]
        for check in plan.checks {
            if containers[check.terminal] == nil { order.append(check.terminal) }
            containers[check.terminal, default: 0] += check.boxes.count
            checks[check.terminal, default: 0] += 1
        }
        return order.map { ($0, containers[$0] ?? 0, checks[$0] ?? 0) }
    }

    private func start(_ plan: Plan) {
        queue = plan.checks
        index = 0
        started = true
    }

    // MARK: During the check

    private var panel: some View {
        VStack(alignment: .leading, spacing: 8) {
            if finished {
                Text("All \(savedCount) checked and saved.")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Brand.navy)
                Button("Done") { dismiss() }
                    .buttonStyle(PrimaryButtonStyle())
            } else if let current {
                Text("\(current.terminal) check \(index + 1)/\(queue.count)")
                    .font(.subheadline.weight(.bold))
                    .foregroundColor(Brand.navy)
                Text(current.boxes.map { Marking.formatContainer($0.number) }.joined(separator: "  ·  "))
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundColor(Brand.muted)
                    .lineLimit(3)
                Text(note ?? "If ShipCSX asks, tick \"Verify you are human\". The containers fill in once the form shows.")
                    .font(.footnote)
                    .foregroundColor(Brand.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if filled.isEmpty && fillTries >= 8 {
                    Button("Fill Containers") { Task { await fill() } }
                        .buttonStyle(PrimaryButtonStyle())
                }
            }
            if !lastSaved.isEmpty {
                ForEach(lastSaved) { row in
                    HStack {
                        Text(Marking.formatContainer(row.number))
                            .font(.system(.caption, design: .monospaced))
                        Spacer()
                        Text(row.status).font(.caption.weight(.semibold))
                    }
                    .foregroundColor(Brand.navy)
                }
            }
        }
        .padding(14)
        .background(Brand.paper.ignoresSafeArea(edges: .bottom))
    }

    private func loadPlan() async {
        guard plan == nil, let api = model.api else { return }
        let query = firstContainerId.map { ["containerId": $0] } ?? [:]
        do {
            plan = try await api.get("/api/shipcsx/plan", query: query)
        } catch {
            loadError = model.handle(error)
        }
    }

    /// Follow the page: fill the form when it shows, save the results when they do.
    private func watch() async {
        guard started else { return }
        while !Task.isCancelled && !finished {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !working, current != nil else { continue }
            switch await page.state() {
            case .challenge:
                note = "Tick \"Verify you are human\" on ShipCSX."
            case .form where filled.isEmpty && fillTries < 8:
                await fill()
            case .results where !filled.isEmpty:
                await saveResults()
            default:
                break
            }
        }
    }

    private func fill() async {
        guard let check = current else { return }
        working = true
        defer { working = false }
        fillTries += 1
        let outcome = await page.fill(check.boxes.map(\.number), terminal: check.terminal)
        if let problem = outcome.problem {
            note = "Couldn't fill the form: \(problem)"
            return
        }
        let typed = check.boxes.filter { box in outcome.filled.contains(ShipcsxPage.equipment(box.number)) }
        guard !typed.isEmpty else {
            note = fillTries >= 8 ? "Couldn't find the container boxes on this page. Tap Fill Containers to try again." : nil
            return
        }
        filled = typed
        // Any the form had no room for go into a check of their own, next.
        let left = check.boxes.filter { !typed.contains($0) }
        if !left.isEmpty {
            queue[index] = Check(terminal: check.terminal, boxes: typed)
            queue.insert(Check(terminal: check.terminal, boxes: left), at: index + 1)
        }
        note = outcome.terminalPicked
            ? "Filled. Tap Search on ShipCSX."
            : "Filled. Select \(check.terminal) as the terminal, then tap Search."
    }

    private func saveResults() async {
        guard let check = current, let api = model.api else { return }
        working = true
        defer { working = false }
        note = "Reading what ShipCSX shows…"
        let tabs = await page.resultsTabs()
        do {
            let payload: SavedPayload = try await api.post(
                "/api/shipcsx/results",
                body: ResultsBody(terminal: check.terminal, containerIds: filled.map(\.containerId), tabs: tabs)
            )
            lastSaved = payload.results
            savedCount += payload.results.count
            onSaved()
        } catch {
            note = model.handle(error)
            return
        }
        filled = []
        fillTries = 0
        if index + 1 < queue.count {
            index += 1
            note = "Saved. Loading the next check…"
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            page.restart()
        } else {
            finished = true
        }
    }
}

/// The ShipCSX page the driver is looking at, for reading and filling it.
@MainActor
final class ShipcsxPage {
    static let lookupURL = URL(string: "https://next.shipcsx.com/#/shipment/lookup")!

    enum State: String { case form, results, challenge, other }

    struct FillOutcome {
        let filled: [String]
        let terminalPicked: Bool
        let problem: String?
    }

    /// One results tab's page text. Encoded straight into the results upload.
    struct ResultsTab: Codable {
        let tab: String?
        let text: String
    }

    fileprivate weak var webView: WKWebView?

    /// How ShipCSX wants the container: initial and serial as one string,
    /// no check digit ("TTRU485022").
    static func equipment(_ number: String) -> String {
        String(Marking.normalize(number).prefix(10))
    }

    /// A fresh lookup form for the next check.
    func restart() {
        webView?.evaluateJavaScript("location.replace('\(Self.lookupURL.absoluteString)'); location.reload();")
    }

    func state() async -> State {
        guard let webView,
              let raw = try? await webView.evaluateJavaScript(Self.stateScript) as? String else { return .other }
        return State(rawValue: raw) ?? .other
    }

    /// Selects the terminal and types the containers in, one row at a time,
    /// the way a person does, so ShipCSX turns Search on. The reference stays
    /// blank. Nothing is submitted: the driver taps Search.
    func fill(_ containers: [String], terminal: String) async -> FillOutcome {
        struct Reply: Decodable {
            let filled: [String]
            let picked: Bool
            let error: String?
        }
        guard let webView,
              let json = try? await webView.callAsyncJavaScript(
                  Self.fillScript,
                  arguments: ["equipment": containers.map(Self.equipment), "terminal": terminal],
                  in: nil,
                  in: .page
              ) as? String,
              let reply = try? JSONDecoder().decode(Reply.self, from: Data(json.utf8)) else {
            return FillOutcome(filled: [], terminalPicked: false, problem: nil)
        }
        return FillOutcome(filled: reply.filled, terminalPicked: reply.picked, problem: reply.error)
    }

    /// The results page, tab by tab: ShipCSX shows one tab's cards at a time,
    /// so each tab with containers in it is opened and read.
    func resultsTabs() async -> [ResultsTab] {
        guard let webView else { return [] }
        if let json = try? await webView.callAsyncJavaScript(Self.resultsScript, arguments: [:], in: nil, in: .page) as? String,
           let tabs = try? JSONDecoder().decode([ResultsTab].self, from: Data(json.utf8)), !tabs.isEmpty {
            return tabs
        }
        let text = (try? await webView.evaluateJavaScript("document.body ? document.body.innerText : ''") as? String) ?? ""
        return [ResultsTab(tab: nil, text: text)]
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
    try {
      const sleep = (ms) => new Promise((done) => setTimeout(done, ms));
      const visible = (el) => !!el && el.getClientRects().length > 0 && getComputedStyle(el).visibility !== 'hidden';
      const norm = (text) => (text || '').replace(/\\s+/g, ' ').trim().toLowerCase();
      const compact = (value) => (value || '').toUpperCase().replace(/[^A-Z0-9]/g, '');
      const press = (el) => {
        for (const kind of ['pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click']) {
          el.dispatchEvent(new MouseEvent(kind, { bubbles: true, cancelable: true, view: window }));
        }
      };
      // A tap, then each character keyed in, then leaving the box: the
      // events ShipCSX waits for before it lets Search be tapped.
      const typeIn = async (el, value) => {
        const setter = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(el), 'value').set;
        el.scrollIntoView({ block: 'center' });
        press(el);
        el.focus();
        el.dispatchEvent(new FocusEvent('focusin', { bubbles: true }));
        setter.call(el, '');
        el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'deleteContentBackward' }));
        for (const ch of value) {
          el.dispatchEvent(new KeyboardEvent('keydown', { key: ch, bubbles: true }));
          el.dispatchEvent(new KeyboardEvent('keypress', { key: ch, bubbles: true }));
          setter.call(el, el.value + ch);
          el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: ch }));
          el.dispatchEvent(new KeyboardEvent('keyup', { key: ch, bubbles: true }));
          await sleep(20);
        }
        el.dispatchEvent(new Event('change', { bubbles: true }));
        el.blur();
        el.dispatchEvent(new FocusEvent('focusout', { bubbles: true }));
      };

      // The terminal. A plain list if the page has one, otherwise the
      // "Select Terminal" box: open it and choose the option.
      const wanted = norm(terminal);
      let picked = false;
      for (const select of document.querySelectorAll('select')) {
        const option = [...select.options].find((o) => norm(o.textContent).includes(wanted));
        if (!option) continue;
        select.selectedIndex = option.index;
        select.dispatchEvent(new Event('input', { bubbles: true }));
        select.dispatchEvent(new Event('change', { bubbles: true }));
        picked = true;
        break;
      }
      if (!picked) {
        const shows = (el) => norm(el.innerText || el.value || el.getAttribute('placeholder'));
        const candidates = [...document.querySelectorAll('ion-select, mat-select, ng-select, p-dropdown, [role="combobox"], [aria-haspopup], button, div, input')]
          .filter((el) => visible(el) && /select terminal|terminal \\(required\\)/.test(shows(el)));
        // The innermost box saying "Select Terminal".
        const trigger = candidates.find((el) => !candidates.some((other) => other !== el && el.contains(other)));
        if (trigger) {
          press(trigger);
          await sleep(700);
          const leaves = [...document.querySelectorAll('body *')]
            .filter((el) => visible(el) && norm(el.innerText) === wanted && ![...el.children].some((child) => norm(child.innerText) === wanted));
          const option = leaves.find((el) => !trigger.contains(el));
          if (option) {
            press(option);
            await sleep(400);
            const ok = [...document.querySelectorAll('button, .alert-button')].filter(visible)
              .find((b) => /^(ok|done|select|apply)$/i.test((b.innerText || '').trim()));
            if (ok) { press(ok); await sleep(400); }
            picked = true;
          }
        }
      }

      // The rows: the equipment box on the left, the reference on the right.
      // ShipCSX shows one row and adds the next once one is typed in.
      const equipmentBoxes = () => {
        const inputs = [...document.querySelectorAll('input, textarea')].filter((el) =>
          visible(el) && !el.readOnly && !el.disabled && !/^(hidden|checkbox|radio|submit|button|search)$/i.test(el.type || ''));
        const groups = [];
        for (const el of inputs) {
          const box = el.getBoundingClientRect();
          const group = groups.find((g) => Math.abs(g.top - box.top) < 8);
          if (group) group.items.push({ el, left: box.left });
          else groups.push({ top: box.top, items: [{ el, left: box.left }] });
        }
        return groups
          .filter((g) => g.items.length === 2)
          .sort((a, b) => a.top - b.top)
          .map((g) => g.items.sort((a, b) => a.left - b.left)[0].el);
      };

      const filled = [];
      for (const container of equipment) {
        let boxes = equipmentBoxes();
        if (boxes.some((box) => compact(box.value) === container)) { filled.push(container); continue; }
        let empty = boxes.find((box) => !box.value);
        for (let wait = 0; !empty && wait < 10; wait++) {
          await sleep(200);
          boxes = equipmentBoxes();
          empty = boxes.find((box) => !box.value);
        }
        if (!empty) break;
        await typeIn(empty, container);
        filled.push(container);
        await sleep(250);
      }
      return JSON.stringify({ filled, picked });
    } catch (error) {
      return JSON.stringify({ filled: [], picked: false, error: String((error && error.message) || error) });
    }
    """

    private static let resultsScript = """
    const sleep = (ms) => new Promise((done) => setTimeout(done, ms));
    const pattern = /^(NOTIFIED|ENROUTE|EN-ROUTE|IN-GATE|OTHERS)\\s*\\((\\d+)\\)$/i;
    const label = (el) => (el.innerText || '').replace(/\\s+/g, ' ').trim();
    const tabs = [...document.querySelectorAll('body *')]
      .filter((el) => pattern.test(label(el)) && ![...el.children].some((child) => pattern.test(label(child))));
    const pages = [];
    for (const tab of tabs) {
      const [, name, count] = label(tab).match(pattern);
      if (Number(count) === 0) continue;
      tab.click();
      await sleep(700);
      pages.push({ tab: name.toUpperCase(), text: document.body.innerText });
    }
    return JSON.stringify(pages);
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
