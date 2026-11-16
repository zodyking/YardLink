import SwiftUI

/// The signed-in person's own details: name, sign-in email, mobile number,
/// password, and for a driver the licence and truck their time card uses.
/// Changing the email, phone or password asks for the current password.
struct AccountSettingsView: View {
    @EnvironmentObject private var model: AppModel
    let user: SessionUser

    @State private var firstName = ""
    @State private var lastName = ""
    @State private var email = ""
    @State private var mobile = ""
    @State private var cdlNumber = ""
    @State private var cdlState = ""
    @State private var truckVin = ""
    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var loaded = false
    @State private var saving: Part?
    @State private var note: String?
    @State private var errorMessage: String?

    private enum Part {
        case name, email, phone, password, driver
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let errorMessage { ErrorBanner(message: errorMessage) }
                if let note { Banner(kind: .success, message: note) }

                if loaded {
                    SectionTitle(text: "Name")
                    Card {
                        labeled("First name") { TextField("First name", text: $firstName).textContentType(.givenName) }
                        labeled("Last name") { TextField("Last name", text: $lastName).textContentType(.familyName) }
                        saveButton("Save Name", part: .name, enabled: !firstName.isEmpty && !lastName.isEmpty) { await saveName() }
                    }

                    if user.isDriver {
                        SectionTitle(text: "License and truck")
                        Card {
                            labeled("CDL number") {
                                TextField("CDL number", text: $cdlNumber)
                                    .textInputAutocapitalization(.characters)
                                    .autocorrectionDisabled()
                            }
                            labeled("CDL state") {
                                TextField("Two letters, like FL", text: $cdlState)
                                    .textInputAutocapitalization(.characters)
                                    .autocorrectionDisabled()
                            }
                            labeled("Truck VIN") {
                                TextField("VIN", text: $truckVin)
                                    .textInputAutocapitalization(.characters)
                                    .autocorrectionDisabled()
                            }
                            Text("These print on your daily time card.")
                                .font(.footnote)
                                .foregroundColor(Brand.muted)
                            saveButton("Save License and Truck", part: .driver, enabled: cdlState.count <= 2) { await saveDriver() }
                        }
                    }

                    SectionTitle(text: "Sign-in and security")
                    Card {
                        labeled("Current password") {
                            SecureField("Needed for the changes below", text: $currentPassword)
                                .textContentType(.password)
                        }
                        Text("Enter your current password, then change your email, mobile number or password.")
                            .font(.footnote)
                            .foregroundColor(Brand.muted)
                    }
                    Card {
                        labeled("Email") {
                            TextField("Email", text: $email)
                                .keyboardType(.emailAddress)
                                .textContentType(.username)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                        saveButton("Change Email", part: .email, enabled: hasPassword && email.contains("@")) { await saveEmail() }
                    }
                    Card {
                        labeled("Mobile number") {
                            TextField("10-digit number", text: $mobile)
                                .keyboardType(.phonePad)
                                .textContentType(.telephoneNumber)
                        }
                        saveButton("Change Mobile Number", part: .phone, enabled: hasPassword && mobile.filter(\.isNumber).count >= 10) { await savePhone() }
                    }
                    Card {
                        labeled("New password") {
                            SecureField("At least 10 characters", text: $newPassword).textContentType(.newPassword)
                        }
                        labeled("New password again") {
                            SecureField("Type it once more", text: $confirmPassword).textContentType(.newPassword)
                        }
                        if !confirmPassword.isEmpty && confirmPassword != newPassword {
                            Text("The two passwords do not match.").font(.footnote).foregroundColor(Brand.danger)
                        }
                        saveButton(
                            "Change Password",
                            part: .password,
                            enabled: hasPassword && newPassword.count >= 10 && newPassword == confirmPassword
                        ) { await savePassword() }
                    }
                } else if errorMessage == nil {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(16)
        }
        .scrollDismissesKeyboard(.interactively)
        .screenBackground()
        .navigationTitle("Account Settings")
        .navigationBarTitleDisplayMode(.inline)
        .lightBar()
        .task { await load() }
    }

    private var hasPassword: Bool { !currentPassword.isEmpty }

    private func labeled<Field: View>(_ label: String, @ViewBuilder field: () -> Field) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel(text: label)
            FieldBox { field() }
        }
    }

    private func saveButton(_ title: String, part: Part, enabled: Bool, action: @escaping () async -> Void) -> some View {
        Button(saving == part ? "Saving…" : title) { Task { await action() } }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(!enabled || saving != nil)
    }

    private func load() async {
        guard let api = model.api, !loaded else { return }
        do {
            let account: AccountInfo = try await api.get("/api/account")
            firstName = account.firstName ?? user.firstName
            lastName = account.lastName ?? user.lastName
            email = account.email ?? user.email
            mobile = account.mobileNumber ?? ""
            cdlNumber = account.driver?.cdlNumber ?? ""
            cdlState = account.driver?.cdlState ?? ""
            truckVin = account.driver?.truckVin ?? ""
            loaded = true
        } catch {
            errorMessage = model.handle(error)
        }
    }

    /// Run one save, show what happened, and keep the other sections usable.
    private func run(_ part: Part, done: String, _ work: (APIClient) async throws -> Void) async {
        guard let api = model.api else { return }
        saving = part
        errorMessage = nil
        note = nil
        defer { saving = nil }
        do {
            try await work(api)
            note = done
        } catch {
            errorMessage = model.handle(error)
        }
    }

    private struct NameChange: Encodable {
        let firstName: String
        let lastName: String
    }

    private func saveName() async {
        await run(.name, done: "Name saved.") { api in
            let _: OkResult = try await api.patch("/api/account/profile", body: NameChange(
                firstName: firstName.trimmingCharacters(in: .whitespaces),
                lastName: lastName.trimmingCharacters(in: .whitespaces)
            ))
        }
        await model.reloadSession()
    }

    private struct DriverChange: Encodable {
        let cdlNumber: String
        let cdlState: String
        let truckVin: String
    }

    private func saveDriver() async {
        await run(.driver, done: "License and truck saved.") { api in
            let _: OkResult = try await api.patch("/api/account/driver", body: DriverChange(
                cdlNumber: cdlNumber.trimmingCharacters(in: .whitespaces),
                cdlState: cdlState.trimmingCharacters(in: .whitespaces),
                truckVin: truckVin.trimmingCharacters(in: .whitespaces)
            ))
        }
    }

    private struct EmailChange: Encodable {
        let currentPassword: String
        let email: String
    }

    private func saveEmail() async {
        await run(.email, done: "Sign-in email changed.") { api in
            let _: OkResult = try await api.post("/api/account/email", body: EmailChange(
                currentPassword: currentPassword,
                email: email.trimmingCharacters(in: .whitespaces)
            ))
        }
        await model.reloadSession()
    }

    private struct PhoneChange: Encodable {
        let currentPassword: String
        let mobileNumber: String
    }

    private func savePhone() async {
        await run(.phone, done: "Mobile number changed.") { api in
            let _: OkResult = try await api.post("/api/account/phone", body: PhoneChange(currentPassword: currentPassword, mobileNumber: mobile))
        }
    }

    private struct PasswordChange: Encodable {
        let currentPassword: String
        let password: String
    }

    private func savePassword() async {
        await run(.password, done: "Password changed.") { api in
            let _: OkResult = try await api.post("/api/account/password", body: PasswordChange(currentPassword: currentPassword, password: newPassword))
        }
        if errorMessage == nil {
            currentPassword = ""
            newPassword = ""
            confirmPassword = ""
        }
    }
}
