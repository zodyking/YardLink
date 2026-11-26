import SwiftUI

/// Add a location, or correct one. The map outline and the compass heading
/// stay in the web app; everything a driver or dispatcher types is here.
struct LocationFormView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    /// Nil when adding.
    let locationId: String?
    let onSaved: () -> Void

    @State private var form: LocationInput
    @State private var saving = false
    @State private var errorMessage: String?
    /// Set when the server finds a location that looks like this one.
    @State private var duplicateWarning: String?

    private static let types: [(value: String, label: String)] = [
        ("COMPANY_YARD", "Company Yard"),
        ("CUSTOMER", "Customer Location"),
        ("MARINE_TERMINAL", "Marine Terminal"),
        ("RAIL_TERMINAL", "Rail Yard"),
    ]

    init(onSaved: @escaping () -> Void) {
        locationId = nil
        self.onSaved = onSaved
        _form = State(initialValue: LocationInput())
    }

    init(record: LocationRecord, onSaved: @escaping () -> Void) {
        locationId = record.id
        self.onSaved = onSaved
        _form = State(initialValue: LocationInput(record))
    }

    private var isRail: Bool { form.type == "RAIL_TERMINAL" || form.type == "MARINE_TERMINAL" }
    private var canSave: Bool { !form.name.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let errorMessage { ErrorBanner(message: errorMessage) }
                    if let duplicateWarning {
                        Banner(kind: .warning, title: "This may already exist", message: duplicateWarning)
                        Button("Save It Anyway") { Task { await save(force: true) } }
                            .buttonStyle(DarkButtonStyle())
                            .disabled(saving)
                    }

                    FieldLabel(text: "What kind of place is it?")
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
                        ForEach(Self.types, id: \.value) { type in
                            Button {
                                form.type = type.value
                            } label: {
                                Text(type.label)
                                    .font(.subheadline.weight(.semibold))
                                    .multilineTextAlignment(.center)
                                    .frame(maxWidth: .infinity, minHeight: 56)
                                    .foregroundColor(form.type == type.value ? .white : Brand.navy)
                                    .background(form.type == type.value ? Brand.navy : Brand.paper)
                                    .clipShape(RoundedRectangle(cornerRadius: Brand.controlRadius, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: Brand.controlRadius, style: .continuous)
                                            .stroke(form.type == type.value ? Brand.navy : Brand.line)
                                    )
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(form.type == type.value ? .isSelected : [])
                        }
                    }

                    SectionTitle(text: "Name and address")
                    Card {
                        field("Name", text: $form.name)
                        field("Street address", text: $form.addressLine1)
                        field("City", text: $form.city)
                        HStack(spacing: 12) {
                            field("State", text: $form.state, capitals: true)
                            field("ZIP", text: $form.postalCode, numeric: true)
                        }
                    }

                    SectionTitle(text: "Getting in")
                    Card {
                        field("Hours", text: $form.hours)
                        Toggle(isOn: $form.appointmentRequired) {
                            Text("Appointment required")
                                .font(.body.weight(.semibold))
                                .foregroundColor(Brand.navy)
                        }
                        .tint(Brand.linkBlue)
                        multiline("Gate instructions", text: $form.gateInstructions)
                        multiline("Notes for drivers", text: $form.driverNotes)
                    }

                    SectionTitle(text: "Phones")
                    Card {
                        field("Main line", text: $form.mainPhone, phone: true)
                        field("Contact name", text: $form.contactName)
                        field("Contact phone", text: $form.contactPhone, phone: true)
                    }

                    if isRail {
                        SectionTitle(text: "CSX")
                        Card {
                            FieldLabel(text: "CSX facility")
                            Text("Shown with containers here when copying them to ShipCSX on the web.")
                                .font(.footnote)
                                .foregroundColor(Brand.muted)
                            ForEach(shipcsxTerminals, id: \.self) { terminal in
                                Button {
                                    form.shipcsxTerminal = form.shipcsxTerminal == terminal ? "" : terminal
                                } label: {
                                    HStack {
                                        Text(terminal).foregroundColor(Brand.navy)
                                        Spacer()
                                        if form.shipcsxTerminal == terminal {
                                            Image(systemName: "checkmark").foregroundColor(Brand.linkBlue)
                                        }
                                    }
                                    .frame(minHeight: 40)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .screenBackground()
            .navigationTitle(locationId == nil ? "Add Location" : "Edit Location")
            .navigationBarTitleDisplayMode(.inline)
            .lightBar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                BottomBar {
                    Button(saving ? "Saving…" : (locationId == nil ? "Add Location" : "Save Changes")) {
                        Task { await save(force: false) }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(saving || !canSave)
                }
            }
        }
    }

    private func field(_ label: String, text: Binding<String>, capitals: Bool = false, numeric: Bool = false, phone: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption.weight(.semibold)).foregroundColor(Brand.muted)
            TextField(label, text: text)
                .font(.body)
                .foregroundColor(Brand.navy)
                .textInputAutocapitalization(capitals ? .characters : .words)
                .keyboardType(phone ? .phonePad : (numeric ? .numbersAndPunctuation : .default))
                .autocorrectionDisabled(capitals || phone)
                .frame(minHeight: 36)
            Divider()
        }
    }

    private func multiline(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption.weight(.semibold)).foregroundColor(Brand.muted)
            TextField(label, text: text, axis: .vertical)
                .font(.body)
                .foregroundColor(Brand.navy)
                .lineLimit(2...6)
                .frame(minHeight: 36)
            Divider()
        }
    }

    /// Adding sends everything; editing sends the same fields so a cleared
    /// box clears the record.
    private struct NewLocation: Encodable {
        let location: LocationInput
        let acknowledgeDuplicates: Bool

        func encode(to encoder: Encoder) throws {
            try location.encode(to: encoder)
            var extra = encoder.container(keyedBy: Key.self)
            try extra.encode(acknowledgeDuplicates, forKey: .acknowledgeDuplicates)
        }

        private enum Key: String, CodingKey {
            case acknowledgeDuplicates
        }
    }

    private func save(force: Bool) async {
        guard let api = model.api, !saving else { return }
        saving = true
        errorMessage = nil
        if force { duplicateWarning = nil }
        defer { saving = false }

        var body = form
        body.name = body.name.trimmingCharacters(in: .whitespaces)
        body.state = body.state.trimmingCharacters(in: .whitespaces).uppercased()

        do {
            if let locationId {
                let _: OkResult = try await api.patch("/api/locations/\(locationId)", body: body)
            } else {
                let _: LocationEnvelope = try await api.post(
                    "/api/locations",
                    body: NewLocation(location: body, acknowledgeDuplicates: force)
                )
            }
            onSaved()
            dismiss()
        } catch {
            // 409 means the server found a location that looks like this one.
            if let apiError = error as? APIError, apiError.status == 409 {
                duplicateWarning = apiError.message
            } else {
                errorMessage = model.handle(error)
            }
        }
    }
}
