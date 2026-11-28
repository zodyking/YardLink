import SwiftUI

/// Create an account with the connected employer. The join code comes from a
/// dispatcher; it is not in the employer code that was scanned.
struct SignUpView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    /// Hands back the address and password, and what the server said, so the
    /// sign-in screen can carry on from there.
    let onCreated: (_ email: String, _ password: String, _ result: SignupResult) -> Void

    @State private var firstName = ""
    @State private var lastName = ""
    @State private var email = ""
    @State private var mobile = ""
    @State private var password = ""
    @State private var joinCode = ""
    @State private var role = "DRIVER"
    @State private var working = false
    @State private var errorMessage: String?
    @FocusState private var focus: Field?

    private enum Field: Hashable { case first, last, email, mobile, password, code }

    private var mobileDigits: String {
        let digits = mobile.filter(\.isNumber)
        return digits.count == 11 && digits.hasPrefix("1") ? String(digits.dropFirst()) : digits
    }

    private var ready: Bool {
        !firstName.trimmed.isEmpty && !lastName.trimmed.isEmpty
            && email.contains("@") && mobileDigits.count == 10
            && password.count >= 10 && !joinCode.trimmed.isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if !model.employerName.isEmpty {
                        Text("Joining \(model.employerName)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(Brand.muted)
                    }

                    if let errorMessage { ErrorBanner(message: errorMessage) }

                    Card {
                        Picker("I am a", selection: $role) {
                            Text("Driver").tag("DRIVER")
                            Text("Dispatcher").tag("DISPATCHER")
                        }
                        .pickerStyle(.segmented)

                        HStack(spacing: 12) {
                            field("First name", text: $firstName, field: .first, next: .last)
                                .textContentType(.givenName)
                            field("Last name", text: $lastName, field: .last, next: .email)
                                .textContentType(.familyName)
                        }
                        field("Email", text: $email, field: .email, next: .mobile, placeholder: "you@company.com")
                            .keyboardType(.emailAddress)
                            .textContentType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        field("Mobile number", text: $mobile, field: .mobile, next: .password, placeholder: "(555) 555-5555")
                            .keyboardType(.phonePad)
                            .textContentType(.telephoneNumber)
                        VStack(alignment: .leading, spacing: 6) {
                            label("Password")
                            SecureField("At least 10 characters", text: $password)
                                .textContentType(.newPassword)
                                .textFieldStyle(.roundedBorder)
                                .focused($focus, equals: .password)
                                .submitLabel(.next)
                                .onSubmit { focus = .code }
                        }
                        field("Join code", text: $joinCode, field: .code, next: nil, placeholder: "From your dispatcher")
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                    }

                    Text(role == "DRIVER"
                         ? "Your dispatcher may need to approve the account before you can sign in."
                         : "Dispatcher accounts may need approval from an existing dispatcher.")
                        .font(.footnote)
                        .foregroundColor(Brand.muted)
                        .multilineTextAlignment(.center)

                    Button(working ? "Creating Account…" : "Create Account", action: submit)
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(working || !ready)
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Brand.mist.ignoresSafeArea())
            .navigationTitle("Create Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.subheadline.weight(.semibold)).foregroundColor(Brand.navy)
    }

    private func field(_ title: String, text: Binding<String>, field: Field, next: Field?, placeholder: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            label(title)
            TextField(placeholder ?? title, text: text)
                .textFieldStyle(.roundedBorder)
                .focused($focus, equals: field)
                .submitLabel(next == nil ? .go : .next)
                .onSubmit {
                    if let next { focus = next } else { submit() }
                }
        }
    }

    private func submit() {
        guard ready, !working else { return }
        working = true
        errorMessage = nil
        focus = nil
        let form = SignupForm(
            firstName: firstName.trimmed,
            lastName: lastName.trimmed,
            email: email.trimmed,
            mobileNumber: mobileDigits,
            password: password,
            inviteCode: joinCode.trimmed,
            role: role
        )
        Task {
            defer { working = false }
            do {
                let result = try await model.signUp(form)
                onCreated(form.email, form.password, result)
                dismiss()
            } catch {
                errorMessage = (error as? APIError)?.message ?? "Could not create the account. Try again."
            }
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
