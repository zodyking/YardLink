import SwiftUI

struct SignInView: View {
    @EnvironmentObject private var model: AppModel
    @State private var email = ""
    @State private var password = ""
    @State private var working = false
    @State private var errorMessage: String?
    @State private var confirmingChange = false
    /// The password was right but the email address is not confirmed yet.
    @State private var needsConfirmation = false
    @State private var resending = false
    @State private var resendNote: String?
    @FocusState private var focus: Field?

    private enum Field { case email, password }

    var body: some View {
        ZStack {
            Brand.mist.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 20) {
                    Image("Logo")
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 160)
                        .padding(.top, 32)
                        .accessibilityLabel("Yard Link")

                    VStack(spacing: 4) {
                        Text("Sign In")
                            .font(.title2.weight(.bold))
                            .foregroundColor(Brand.navy)
                        if !model.employerName.isEmpty {
                            Text(model.employerName)
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(Brand.muted)
                        }
                    }

                    if let errorMessage {
                        ErrorBanner(message: errorMessage)
                    }

                    if needsConfirmation {
                        Card {
                            Button(resending ? "Sending…" : "Send the Email Again", action: resend)
                                .buttonStyle(SecondaryButtonStyle())
                                .disabled(resending)
                            if let resendNote {
                                Text(resendNote)
                                    .font(.footnote)
                                    .foregroundColor(Brand.muted)
                            }
                        }
                    }

                    Card {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Email").font(.subheadline.weight(.semibold)).foregroundColor(Brand.navy)
                            TextField("you@company.com", text: $email)
                                .keyboardType(.emailAddress)
                                .textContentType(.username)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .textFieldStyle(.roundedBorder)
                                .focused($focus, equals: .email)
                                .submitLabel(.next)
                                .onSubmit { focus = .password }
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Password").font(.subheadline.weight(.semibold)).foregroundColor(Brand.navy)
                            SecureField("Password", text: $password)
                                .textContentType(.password)
                                .textFieldStyle(.roundedBorder)
                                .focused($focus, equals: .password)
                                .submitLabel(.go)
                                .onSubmit(submit)
                        }
                        Button(working ? "Signing In…" : "Sign In", action: submit)
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(working || email.isEmpty || password.isEmpty)
                    }

                    VStack(spacing: 4) {
                        Text("New here? Create your account in a browser at")
                            .font(.footnote)
                            .foregroundColor(Brand.muted)
                        if let server = model.serverURL {
                            Link("\(server.host ?? server.absoluteString)/signup", destination: server.appendingPathComponent("signup"))
                                .font(.footnote.weight(.semibold))
                        }
                        Text("You will need the join code from your dispatcher.")
                            .font(.footnote)
                            .foregroundColor(Brand.muted)
                    }
                    .multilineTextAlignment(.center)

                    Button("Connect to a different employer") { confirmingChange = true }
                        .font(.footnote.weight(.semibold))
                        .frame(minHeight: 44)
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .confirmationDialog(
            "Disconnect from \(model.employerName.isEmpty ? "this employer" : model.employerName)?",
            isPresented: $confirmingChange,
            titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive) { model.disconnect() }
            Button("Stay Connected", role: .cancel) {}
        } message: {
            Text("You will need to scan an employer code again.")
        }
    }

    private func submit() {
        guard !working, !email.isEmpty, !password.isEmpty else { return }
        working = true
        errorMessage = nil
        needsConfirmation = false
        resendNote = nil
        focus = nil
        Task {
            do {
                try await model.signIn(email: email.trimmingCharacters(in: .whitespaces), password: password)
                password = ""
            } catch {
                let apiError = error as? APIError
                errorMessage = apiError?.message ?? "Could not sign in. Try again."
                needsConfirmation = apiError?.flags["emailUnverified"] == true
            }
            working = false
        }
    }

    private func resend() {
        guard !resending else { return }
        resending = true
        resendNote = nil
        Task {
            resendNote = await model.resendConfirmation(email: email.trimmingCharacters(in: .whitespaces))
            resending = false
        }
    }
}
