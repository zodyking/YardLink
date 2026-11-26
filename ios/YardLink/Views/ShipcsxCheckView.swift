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

    struct Saved: Decodable {
        let containerId: String
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
        let listedOnly: Bool
    }

    @State private var page = ShipcsxPage()
    @State private var plan: Plan?
    @State private var loadError: String?
    @State private var started = false
    @State private var queue: [Check] = []
    @State private var index = 0
    /// Containers typed into the current search.
    @State private var filled: [Box] = []
    @State private var working = false
    @State private var savedCount = 0
    /// These results were read already; wait for the page to change.
    @State private var resultsRead = false
    /// Reads of this results page that found none of the check's containers.
    @State private var emptyReads = 0
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
            VStack(spacing: 20) {
                ZStack {
                    Circle().fill(Brand.skyWash).frame(width: 72, height: 72)
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundColor(Brand.linkBlue)
                }
                .padding(.top, 24)

                VStack(spacing: 8) {
                    Text(plan.checks.isEmpty ? "Nothing to check" : "System-wide check")
                        .font(.title2.weight(.bold))
                        .foregroundColor(Brand.navy)
                    Text(plan.checks.isEmpty
                         ? "No loaded containers, or containers at customers or company yards, right now."
                         : "You're about to check every container in the system on ShipCSX.")
                        .font(.subheadline)
                        .foregroundColor(Brand.muted)
                        .multilineTextAlignment(.center)
                }

                if !plan.checks.isEmpty {
                    HStack(spacing: 12) {
                        stat("\(plan.total)", plan.total == 1 ? "Container" : "Containers")
                        stat("\(plan.checks.count)", plan.checks.count == 1 ? "Check" : "Checks")
                    }

                    VStack(spacing: 0) {
                        ForEach(Array(locationCounts(plan).enumerated()), id: \.element.terminal) { offset, line in
                            if offset > 0 { Divider() }
                            HStack(spacing: 12) {
                                Image(systemName: "tram.fill")
                                    .foregroundColor(Brand.linkBlue)
                                    .frame(width: 24)
                                Text(line.terminal)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundColor(Brand.navy)
                                Spacer()
                                Text("\(line.containers) \(line.containers == 1 ? "container" : "containers")")
                                    .font(.footnote)
                                    .foregroundColor(Brand.muted)
                            }
                            .padding(.horizontal, 16)
                            .frame(minHeight: 52)
                        }
                    }
                    .cardSurface()

                    VStack(alignment: .leading, spacing: 10) {
                        step(1, "Tick \"Verify you are human\" if ShipCSX asks.")
                        step(2, "The app fills in the location's containers. Tap Search.")
                        step(3, "Results are saved and the next location loads.")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .safeAreaInset(edge: .bottom) {
            if !plan.checks.isEmpty {
                Button("Start Check") { start(plan) }
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Brand.mist.ignoresSafeArea(edges: .bottom))
            }
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title.weight(.bold)).foregroundColor(Brand.navy)
            Text(label).font(.footnote).foregroundColor(Brand.muted)
        }
        .frame(maxWidth: .infinity, minHeight: 80)
        .cardSurface()
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundColor(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Brand.linkBlue))
            Text(text)
                .font(.subheadline)
                .foregroundColor(Brand.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func locationCounts(_ plan: Plan) -> [(terminal: String, containers: Int)] {
        var order: [String] = []
        var containers: [String: Int] = [:]
        for check in plan.checks {
            if containers[check.terminal] == nil { order.append(check.terminal) }
            containers[check.terminal, default: 0] += check.boxes.count
        }
        return order.map { ($0, containers[$0] ?? 0) }
    }

    private func start(_ plan: Plan) {
        queue = plan.checks
        index = 0
        started = true
    }

    // MARK: During the check

    private var panel: some View {
        HStack(spacing: 12) {
            Image(systemName: finished ? "checkmark.circle.fill" : "tram.fill")
                .font(.title3)
                .foregroundColor(finished ? Brand.ok : Brand.linkBlue)
            VStack(alignment: .leading, spacing: 2) {
                if finished {
                    Text("All \(savedCount) checked and saved")
                        .font(.subheadline.weight(.bold))
                        .foregroundColor(Brand.navy)
                } else if let current {
                    Text("\(current.terminal) check \(index + 1)/\(queue.count)")
                        .font(.subheadline.weight(.bold))
                        .foregroundColor(Brand.navy)
                    Text(note ?? "Filling in \(current.boxes.count) \(current.boxes.count == 1 ? "container" : "containers")…")
                        .font(.footnote)
                        .foregroundColor(Brand.muted)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if finished {
                Button("Done") { dismiss() }.font(.subheadline.weight(.semibold))
            } else if working {
                ProgressView()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Brand.paper.ignoresSafeArea(edges: .bottom))
        .overlay(Rectangle().fill(Brand.line).frame(height: 1), alignment: .top)
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
            let state = await page.state()
            if state != .results { resultsRead = false }
            switch state {
            case .challenge:
                note = "Tick \"Verify you are human\" on ShipCSX."
            case .form where filled.isEmpty:
                await fill()
            case .filled where filled.isEmpty:
                note = "The containers didn't go in. Tap reload to try again."

            case .results where !resultsRead:
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
        let outcome = await page.fill(check.boxes.map(\.number), terminal: check.terminal)
        if let problem = outcome.problem {
            note = "Couldn't fill the form: \(problem)"
            return
        }
        let typed = check.boxes.filter { box in outcome.filled.contains(ShipcsxPage.equipment(box.number)) }
        guard !typed.isEmpty else {
            note = "The containers didn't go in. Tap reload to try again."
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
        resultsRead = true
        defer { working = false }
        note = "Reading what ShipCSX shows…"
        let tabs = await page.resultsTabs()
        do {
            let payload: SavedPayload = try await api.post(
                "/api/shipcsx/results",
                // Typed by hand: save what the results list, from this check's containers.
                body: ResultsBody(
                    terminal: check.terminal,
                    containerIds: (filled.isEmpty ? check.boxes : filled).map(\.containerId),
                    tabs: tabs,
                    listedOnly: filled.isEmpty
                )
            )
            if payload.results.isEmpty && emptyReads < 3 {
                emptyReads += 1
                note = "Waiting for ShipCSX's results to load…"
                resultsRead = false
                return
            }
            emptyReads = 0
            savedCount += payload.results.count
            note = "Saved \(payload.results.count) of \(check.boxes.count)."
            onSaved()
        } catch {
            note = "Couldn't save: \(model.handle(error)) Tap Search again to retry."
            return
        }
        filled = []
        if index + 1 < queue.count {
            index += 1
            note = "\(note ?? "Saved.") Loading the next check…"
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

    enum State: String { case form, filled, results, challenge, other }

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
              (try? await webView.callAsyncJavaScript(
                  Self.fillScript,
                  arguments: ["equipment": containers.map(Self.equipment), "terminal": terminal],
                  in: nil,
                  in: .page
              ) as? String) == "started" else {
            return FillOutcome(filled: [], terminalPicked: false, problem: nil)
        }
        // A person's pace: about a second a container. Give it plenty.
        for _ in 0..<(40 + containers.count * 8) {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let json = try? await webView.evaluateJavaScript("window.__yardlinkFillResult || ''") as? String,
                  !json.isEmpty else { continue }
            guard let reply = try? JSONDecoder().decode(Reply.self, from: Data(json.utf8)) else { break }
            return FillOutcome(filled: reply.filled, terminalPicked: reply.picked, problem: reply.error)
        }
        return FillOutcome(filled: [], terminalPicked: false, problem: nil)
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
      if (/equipment\\s*#/i.test(text) && document.querySelector('input')) return window.__yardlinkFill ? 'filled' : 'form';
      return 'other';
    })()
    """

    private static let fillScript = """
    // One fill per page load: a second one would type over the first. It
    // runs on its own; the app reads how it went from the page.
    if (window.__yardlinkFill) return 'busy';
    window.__yardlinkFill = true;
    window.__yardlinkFillResult = null;
    (async () => {
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
        let typed = '';
        for (const ch of value) {
          el.dispatchEvent(new KeyboardEvent('keydown', { key: ch, bubbles: true }));
          el.dispatchEvent(new KeyboardEvent('keypress', { key: ch, bubbles: true }));
          typed += ch;
          setter.call(el, typed);
          el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: ch }));
          el.dispatchEvent(new KeyboardEvent('keyup', { key: ch, bubbles: true }));
          await sleep(45);
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
      // Row `index`, once ShipCSX has put it on the page.
      const rowAt = async (index) => {
        for (let wait = 0; wait < 25; wait++) {
          const boxes = equipmentBoxes();
          if (boxes[index]) return boxes[index];
          await sleep(200);
        }
        return null;
      };

      // Each container in its own row, in order, at a person's pace: type
      // it, then wait for ShipCSX to add the row below before the next one.
      const filled = [];
      for (let index = 0; index < equipment.length; index++) {
        const container = equipment[index];
        const box = await rowAt(index);
        if (!box) break;
        if (!compact(box.value).startsWith(container)) await typeIn(box, container);
        filled.push(container);
        if (index + 1 < equipment.length && !(await rowAt(index + 1))) break;
        await sleep(250);
      }
      window.__yardlinkFillResult = JSON.stringify({ filled, picked });
    } catch (error) {
      window.__yardlinkFillResult = JSON.stringify({ filled: [], picked: false, error: String((error && error.message) || error) });
    }
    })();
    return 'started';
    """

    private static let resultsScript = """
    const sleep = (ms) => new Promise((done) => setTimeout(done, ms));
    // The heading shows before the cards: wait for container numbers, then
    // for the page to stop changing.
    const cardsShown = () => /\\b[A-Z]{4}\\s?\\d{6}/.test(document.body.innerText.split(/lookup results/i)[1] || '');
    for (let wait = 0; wait < 30 && !cardsShown(); wait++) await sleep(500);
    let last = '';
    for (let wait = 0; wait < 10 && document.body.innerText !== last; wait++) {
      last = document.body.innerText;
      await sleep(400);
    }
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
