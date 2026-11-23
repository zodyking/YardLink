import SwiftUI
import UIKit

/// Snap a photo of a diesel receipt, let the server suggest the gallons and
/// total, confirm or correct them, and see the week's diesel spend at a
/// glance. Driver-facing only — this lives in the More tab, which is the
/// app's de facto Settings page, and nothing here is visible to dispatch.
struct FuelReceiptsView: View {
    @EnvironmentObject private var model: AppModel

    @State private var weeks: [FuelReceiptWeek] = []
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var capturing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let errorMessage { ErrorBanner(message: errorMessage) }

                if loading {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 160)
                } else if weeks.isEmpty {
                    EmptyNote(
                        title: "No receipts yet",
                        detail: "Snap a photo of a diesel receipt and it's tracked here, week by week."
                    )
                } else {
                    ForEach(weeks) { week in
                        FuelReceiptWeekCard(week: week, onChanged: { await load() })
                    }
                }
            }
            .padding(16)
            .padding(.bottom, 70)
        }
        .scrollDismissesKeyboard(.interactively)
        .screenBackground()
        .navigationTitle("Fuel Receipts")
        .navigationBarTitleDisplayMode(.inline)
        .lightBar()
        .safeAreaInset(edge: .bottom) {
            BottomBar {
                Button {
                    capturing = true
                } label: {
                    Label("Snap a Receipt", systemImage: "camera.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
        .sheet(isPresented: $capturing) {
            FuelReceiptCaptureSheet(onSaved: { Task { await load() } })
                .sheetChrome()
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        guard let api = model.api else { return }
        errorMessage = nil
        do {
            let list: FuelReceiptWeekList = try await api.get("/api/fuel-receipts")
            weeks = list.weeks
        } catch {
            errorMessage = model.handle(error)
        }
        loading = false
    }
}

/// Text built for one receipt or a whole week, the same emoji-tagged plain
/// style as a trip update — each platform builds its own copy; nothing
/// here is shared with the server.
enum FuelReceiptMessage {
    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d/yy"
        return formatter
    }()

    private static func money(_ value: Double) -> String { String(format: "$%.2f", value) }
    private static func perGallon(_ value: Double?) -> String { value.map { String(format: "$%.3f", $0) } ?? "—" }

    static func single(_ receipt: FuelReceiptSummary) -> String {
        var lines = ["Fuel Receipt ⛽️", day.string(from: receipt.purchasedAt)]
        if let station = receipt.stationName, !station.isEmpty { lines.append(station) }
        lines.append("Gallons: \(String(format: "%.3f", receipt.gallons))")
        lines.append("Total: \(money(receipt.totalAmount))")
        lines.append("Per gallon: \(perGallon(receipt.pricePerGallon))")
        return lines.joined(separator: "\n")
    }

    static func weekly(_ week: FuelReceiptWeek) -> String {
        guard let start = isoDate(week.weekStart), let end = isoDate(week.weekEnd) else {
            return "Weekly Fuel ⛽️"
        }
        var lines = ["Weekly Fuel ⛽️", "\(day.string(from: start)) – \(day.string(from: end))"]
        lines.append("Receipts: \(week.receipts.count)")
        lines.append("Gallons: \(String(format: "%.3f", week.totalGallons))")
        lines.append("Total: \(money(week.totalAmount))")
        lines.append("Avg per gallon: \(perGallon(week.averagePricePerGallon))")
        return lines.joined(separator: "\n")
    }

    /// Parsed in the device's own time zone, like `Format`'s own ISO-date
    /// parsing — the date is a plain calendar day with no time zone of its
    /// own, so this and the formatters that display it must agree, not pin
    /// to UTC, or the day can shift by one.
    fileprivate static func isoDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: text)
    }
}

/// One week: the Monday-through-Sunday total up top, then every receipt
/// that made it up, newest first.
private struct FuelReceiptWeekCard: View {
    @EnvironmentObject private var model: AppModel
    let week: FuelReceiptWeek
    let onChanged: () async -> Void

    @State private var editing: FuelReceiptSummary?
    @State private var texting = false
    @State private var textAttachments: [(data: Data, fileName: String)] = []
    @State private var preparingText = false

    private var dateRange: String {
        guard let start = FuelReceiptMessage.isoDate(week.weekStart), let end = FuelReceiptMessage.isoDate(week.weekEnd) else {
            return week.weekStart
        }
        return "\(Self.shortDay.string(from: start)) – \(Self.shortDay.string(from: end))"
    }

    private static let shortDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(text: dateRange)
            Card {
                HStack(alignment: .top, spacing: 8) {
                    FactCell(label: "Gallons", value: String(format: "%.1f", week.totalGallons))
                    FactCell(label: "Total", value: String(format: "$%.2f", week.totalAmount))
                    FactCell(label: "Per Gal", value: week.averagePricePerGallon.map { String(format: "$%.3f", $0) } ?? "—")
                }

                Divider()

                ForEach(week.receipts) { receipt in
                    Button { editing = receipt } label: {
                        FuelReceiptRow(receipt: receipt)
                    }
                    .buttonStyle(.plain)
                }

                if MessageComposer.isAvailable {
                    Button {
                        Task { await openWeeklyText() }
                    } label: {
                        Label(preparingText ? "Getting the photos…" : "Text This Week", systemImage: "message.fill")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(preparingText)
                }
            }
        }
        .sheet(item: $editing) { receipt in
            FuelReceiptDetailSheet(
                receipt: receipt,
                onChanged: { Task { await onChanged() } }
            )
            .sheetChrome()
        }
        .sheet(isPresented: $texting) {
            MessageComposer(body: FuelReceiptMessage.weekly(week), attachments: textAttachments)
                .ignoresSafeArea()
        }
    }

    /// Fetch every receipt's photo for the week, then hand the summary and
    /// the photos to the phone's own Messages app.
    private func openWeeklyText() async {
        guard let api = model.api else { return }
        preparingText = true
        defer { preparingText = false }
        var ready: [(data: Data, fileName: String)] = []
        for receipt in week.receipts {
            if let data = try? await api.data("/api/fuel-receipts/\(receipt.id)/file") {
                ready.append((data, "receipt-\(receipt.id.prefix(8)).jpg"))
            }
        }
        textAttachments = ready
        texting = true
    }
}

private struct FuelReceiptRow: View {
    let receipt: FuelReceiptSummary

    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, MMM d"
        return formatter
    }()

    var body: some View {
        HStack(spacing: 12) {
            FuelReceiptImage(receiptId: receipt.id)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Brand.line))

            VStack(alignment: .leading, spacing: 2) {
                Text((receipt.stationName?.isEmpty == false ? receipt.stationName : nil) ?? "Fuel receipt")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Brand.navy)
                Text("\(Self.day.string(from: receipt.purchasedAt)) · \(String(format: "%.3f gal", receipt.gallons))")
                    .font(.caption)
                    .foregroundColor(Brand.muted)
            }
            Spacer(minLength: 0)
            Text(String(format: "$%.2f", receipt.totalAmount))
                .font(.subheadline.weight(.bold))
                .foregroundColor(Brand.navy)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundColor(Brand.muted.opacity(0.6))
        }
        .padding(.vertical, 4)
    }
}

/// A receipt photo stored on the server, loaded with the signed-in session.
/// Kept separate from `ServerImage`, which is hardcoded to the documents
/// endpoint.
struct FuelReceiptImage: View {
    @EnvironmentObject private var model: AppModel
    let receiptId: String

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            Brand.mist
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if failed {
                Image(systemName: "fuelpump.fill").foregroundColor(Brand.muted)
            } else {
                ProgressView()
            }
        }
        .task(id: receiptId) {
            guard image == nil, let api = model.api else { return }
            if let data = try? await api.data("/api/fuel-receipts/\(receiptId)/file"), let loaded = UIImage(data: data) {
                image = loaded
            } else {
                failed = true
            }
        }
    }
}

// MARK: - Capture and confirm

/// Snap a photo, let the server suggest the numbers, then confirm or fix
/// them before anything is saved — the same "suggest, confirm" rule the
/// container/chassis scanner follows.
struct FuelReceiptCaptureSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let onSaved: () -> Void

    @State private var image: UIImage?
    @State private var showingCamera = true
    @State private var extracting = false
    @State private var rawText: String?

    @State private var purchasedAt = Date()
    @State private var stationName = ""
    @State private var gallonsText = ""
    @State private var totalText = ""
    @State private var notes = ""
    @State private var saving = false
    @State private var errorMessage: String?

    private var gallons: Double? { Double(gallonsText) }
    private var totalAmount: Double? { Double(totalText) }
    private var pricePerGallon: Double? {
        guard let gallons, gallons > 0, let totalAmount else { return nil }
        return totalAmount / gallons
    }
    private var canSave: Bool {
        guard let gallons, gallons > 0, let totalAmount, totalAmount > 0 else { return false }
        return image != nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let errorMessage { ErrorBanner(message: errorMessage) }

                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 220)
                            .clipShape(RoundedRectangle(cornerRadius: Brand.controlRadius, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: Brand.controlRadius, style: .continuous).stroke(Brand.line))

                        if extracting {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("Reading the receipt…").font(.footnote).foregroundColor(Brand.muted)
                            }
                        }

                        FieldLabel(text: "Date")
                        FieldBox {
                            DatePicker("Date", selection: $purchasedAt, displayedComponents: [.date, .hourAndMinute])
                                .labelsHidden()
                        }

                        FieldLabel(text: "Station (optional)")
                        FieldBox { TextField("Station name", text: $stationName) }

                        FieldLabel(text: "Gallons")
                        FieldBox {
                            TextField("0.000", text: $gallonsText)
                                .keyboardType(.decimalPad)
                        }

                        FieldLabel(text: "Total paid")
                        FieldBox {
                            TextField("0.00", text: $totalText)
                                .keyboardType(.decimalPad)
                        }

                        if let pricePerGallon {
                            Text("That's \(String(format: "$%.3f", pricePerGallon)) a gallon.")
                                .font(.footnote)
                                .foregroundColor(Brand.muted)
                        }

                        FieldLabel(text: "Notes (optional)")
                        FieldBox {
                            TextField("Anything worth remembering", text: $notes, axis: .vertical)
                                .lineLimit(2...4)
                        }

                        Button("Retake Photo") { retake() }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .screenBackground()
            .navigationTitle("Fuel Receipt")
            .navigationBarTitleDisplayMode(.inline)
            .lightBar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if image != nil {
                    BottomBar {
                        Button(saving ? "Saving…" : "Save Receipt") { Task { await save() } }
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(saving || extracting || !canSave)
                    }
                }
            }
            .fullScreenCover(isPresented: $showingCamera, onDismiss: handleCameraDismiss) {
                CameraCapture { captured in
                    image = captured
                    Task { await extract(captured) }
                }
                .ignoresSafeArea()
            }
        }
    }

    /// No photo means nothing to confirm — close the whole sheet instead of
    /// leaving an empty form behind.
    private func handleCameraDismiss() {
        if image == nil { dismiss() }
    }

    private func retake() {
        image = nil
        rawText = nil
        showingCamera = true
    }

    private struct ExtractPayload: Encodable { let dataUrl: String }

    private func extract(_ image: UIImage) async {
        guard let api = model.api, let dataUrl = image.jpegDataUrl(maxDimension: 2000) else { return }
        extracting = true
        errorMessage = nil
        defer { extracting = false }
        do {
            let result: FuelReceiptExtractionEnvelope = try await api.post("/api/fuel-receipts/extract", body: ExtractPayload(dataUrl: dataUrl), patient: true)
            let extraction = result.extraction
            rawText = extraction.rawText
            if let gallons = extraction.gallons { gallonsText = String(format: "%.3f", gallons) }
            if let totalAmount = extraction.totalAmount { totalText = String(format: "%.2f", totalAmount) }
            if let stationName = extraction.stationName { self.stationName = stationName }
            if let purchasedAt = extraction.purchasedAt { self.purchasedAt = purchasedAt }
        } catch {
            // A failed read is not fatal — the driver can still type the
            // numbers straight off the receipt in front of them.
            errorMessage = model.handle(error)
        }
    }

    private struct SavePayload: Encodable {
        let dataUrl: String
        let purchasedAt: String
        let gallons: Double
        let totalAmount: Double
        let stationName: String?
        let notes: String?
        let ocrText: String?
    }

    private func save() async {
        guard let api = model.api, let image, let dataUrl = image.jpegDataUrl(maxDimension: 2000),
              let gallons, let totalAmount
        else { return }
        saving = true
        errorMessage = nil
        defer { saving = false }

        let trimmedStation = stationName.trimmingCharacters(in: .whitespaces)
        let trimmedNotes = notes.trimmingCharacters(in: .whitespaces)
        let payload = SavePayload(
            dataUrl: dataUrl,
            purchasedAt: ISO8601DateFormatter().string(from: purchasedAt),
            gallons: gallons,
            totalAmount: totalAmount,
            stationName: trimmedStation.isEmpty ? nil : trimmedStation,
            notes: trimmedNotes.isEmpty ? nil : trimmedNotes,
            ocrText: rawText
        )

        do {
            let _: FuelReceiptEnvelope = try await api.post("/api/fuel-receipts", body: payload, patient: true)
            onSaved()
            dismiss()
        } catch {
            errorMessage = model.handle(error)
        }
    }
}

// MARK: - Detail, edit and single-receipt text

/// Fix a misread amount, remove a receipt, or text this one receipt on its
/// own.
private struct FuelReceiptDetailSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let receipt: FuelReceiptSummary
    let onChanged: () -> Void

    @State private var purchasedAt: Date
    @State private var stationName: String
    @State private var gallonsText: String
    @State private var totalText: String
    @State private var notes: String
    @State private var saving = false
    @State private var deleting = false
    @State private var confirmingDelete = false
    @State private var errorMessage: String?
    @State private var texting = false
    @State private var textAttachment: (data: Data, fileName: String)?
    @State private var preparingText = false

    init(receipt: FuelReceiptSummary, onChanged: @escaping () -> Void) {
        self.receipt = receipt
        self.onChanged = onChanged
        _purchasedAt = State(initialValue: receipt.purchasedAt)
        _stationName = State(initialValue: receipt.stationName ?? "")
        _gallonsText = State(initialValue: String(format: "%.3f", receipt.gallons))
        _totalText = State(initialValue: String(format: "%.2f", receipt.totalAmount))
        _notes = State(initialValue: receipt.notes ?? "")
    }

    private var gallons: Double? { Double(gallonsText) }
    private var totalAmount: Double? { Double(totalText) }
    private var pricePerGallon: Double? {
        guard let gallons, gallons > 0, let totalAmount else { return nil }
        return totalAmount / gallons
    }
    private var canSave: Bool {
        guard let gallons, gallons > 0, let totalAmount, totalAmount > 0 else { return false }
        return true
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let errorMessage { ErrorBanner(message: errorMessage) }

                    FuelReceiptImage(receiptId: receipt.id)
                        .frame(maxWidth: .infinity, minHeight: 180, maxHeight: 220)
                        .clipShape(RoundedRectangle(cornerRadius: Brand.controlRadius, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Brand.controlRadius, style: .continuous).stroke(Brand.line))

                    FieldLabel(text: "Date")
                    FieldBox {
                        DatePicker("Date", selection: $purchasedAt, displayedComponents: [.date, .hourAndMinute])
                            .labelsHidden()
                    }

                    FieldLabel(text: "Station (optional)")
                    FieldBox { TextField("Station name", text: $stationName) }

                    FieldLabel(text: "Gallons")
                    FieldBox {
                        TextField("0.000", text: $gallonsText)
                            .keyboardType(.decimalPad)
                    }

                    FieldLabel(text: "Total paid")
                    FieldBox {
                        TextField("0.00", text: $totalText)
                            .keyboardType(.decimalPad)
                    }

                    if let pricePerGallon {
                        Text("That's \(String(format: "$%.3f", pricePerGallon)) a gallon.")
                            .font(.footnote)
                            .foregroundColor(Brand.muted)
                    }

                    FieldLabel(text: "Notes (optional)")
                    FieldBox {
                        TextField("Anything worth remembering", text: $notes, axis: .vertical)
                            .lineLimit(2...4)
                    }

                    Button(saving ? "Saving…" : "Save Changes") { Task { await save() } }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(saving || !canSave)

                    if MessageComposer.isAvailable {
                        Button {
                            Task { await openText() }
                        } label: {
                            Label(preparingText ? "Getting the photo…" : "Send as a Text", systemImage: "message.fill")
                                .frame(maxWidth: .infinity, minHeight: 48)
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(preparingText)
                    }

                    Button(deleting ? "Removing…" : "Remove Receipt", role: .destructive) {
                        confirmingDelete = true
                    }
                    .buttonStyle(DangerTextButtonStyle())
                    .disabled(deleting)
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .screenBackground()
            .navigationTitle("Fuel Receipt")
            .navigationBarTitleDisplayMode(.inline)
            .lightBar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .sheet(isPresented: $texting) {
                MessageComposer(body: FuelReceiptMessage.single(receipt), attachments: textAttachment.map { [$0] } ?? [])
                    .ignoresSafeArea()
            }
            .confirmPrompt(
                "Remove this receipt?",
                message: "This takes it out of the week's total. It cannot be undone.",
                isPresented: $confirmingDelete,
                cancelLabel: "Keep",
                actions: [.destructive("Remove") { Task { await delete() } }]
            )
        }
    }

    private func openText() async {
        guard let api = model.api else { return }
        preparingText = true
        defer { preparingText = false }
        if let data = try? await api.data("/api/fuel-receipts/\(receipt.id)/file") {
            textAttachment = (data, "receipt-\(receipt.id.prefix(8)).jpg")
        }
        texting = true
    }

    private struct UpdatePayload: Encodable {
        let purchasedAt: String
        let gallons: Double
        let totalAmount: Double
        let stationName: String?
        let notes: String?
    }

    private func save() async {
        guard let api = model.api, let gallons, let totalAmount else { return }
        saving = true
        errorMessage = nil
        defer { saving = false }

        let trimmedStation = stationName.trimmingCharacters(in: .whitespaces)
        let trimmedNotes = notes.trimmingCharacters(in: .whitespaces)
        let payload = UpdatePayload(
            purchasedAt: ISO8601DateFormatter().string(from: purchasedAt),
            gallons: gallons,
            totalAmount: totalAmount,
            stationName: trimmedStation.isEmpty ? nil : trimmedStation,
            notes: trimmedNotes.isEmpty ? nil : trimmedNotes
        )

        do {
            let _: FuelReceiptEnvelope = try await api.patch("/api/fuel-receipts/\(receipt.id)", body: payload)
            onChanged()
            dismiss()
        } catch {
            errorMessage = model.handle(error)
        }
    }

    private func delete() async {
        guard let api = model.api else { return }
        deleting = true
        errorMessage = nil
        defer { deleting = false }
        do {
            let _: OkResult = try await api.delete("/api/fuel-receipts/\(receipt.id)")
            onChanged()
            dismiss()
        } catch {
            errorMessage = model.handle(error)
        }
    }
}
