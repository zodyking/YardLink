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
    /// Details are saved behind Face ID for this employer.
    @State private var faceIDSaved = false
    /// A password sign-in just worked; offer to keep it behind Face ID.
    @State private var offerFaceID: FaceIDLogin.Saved?
    @State private var creatingAccount = false
    /// What happens next for an account just created here.
    @State private var signupNote: String?

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

                    if let signupNote {
                        Card {
                            Label(signupNote, systemImage: "checkmark.circle.fill")
                                .font(.subheadline)
                                .foregroundColor(Brand.navy)
                        }
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
                        if faceIDSaved, let name = FaceIDLogin.biometryName {
                            Button {
                                signInWithFaceID()
                            } label: {
                                Label("Sign In with \(name)", systemImage: FaceIDLogin.symbol)
                            }
                            .buttonStyle(SecondaryButtonStyle())
                            .disabled(working)
                        }
                    }

                    VStack(spacing: 8) {
                        Text("New here?")
                            .font(.footnote)
                            .foregroundColor(Brand.muted)
                        Button("Create an Account") { creatingAccount = true }
                            .buttonStyle(SecondaryButtonStyle())
                            .disabled(working)
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
        .sheet(isPresented: $creatingAccount) {
            SignUpView(onCreated: accountCreated)
                .environmentObject(model)
        }
        .task {
            faceIDSaved = FaceIDLogin.isSaved(for: model.serverURL)
            if faceIDSaved { signInWithFaceID() }
        }
        .confirmPrompt(
            "Use \(FaceIDLogin.biometryName ?? "Face ID") next time?",
            message: "Sign in with a glance instead of typing your password.",
            isPresented: Binding(get: { offerFaceID != nil }, set: { if !$0 { offerFaceID = nil } }),
            cancelLabel: "Not Now",
            actions: [.primary("Use \(FaceIDLogin.biometryName ?? "Face ID")") { finish(keeping: offerFaceID) }],
            onCancel: { finish(keeping: nil) }
        )
        .confirmPrompt(
            "Disconnect from \(model.employerName.isEmpty ? "this employer" : model.employerName)?",
            message: "You will need to scan an employer code again.",
            isPresented: $confirmingChange,
            cancelLabel: "Stay Connected",
            actions: [.destructive("Disconnect") { model.disconnect() }]
        )
    }

    private func submit() {
        guard !working, !email.isEmpty, !password.isEmpty else { return }
        working = true
        errorMessage = nil
        needsConfirmation = false
        resendNote = nil
        signupNote = nil
        focus = nil
        Task {
            let address = email.trimmingCharacters(in: .whitespaces)
            do {
                try await model.verifyCredentials(email: address, password: password)
                let saved = FaceIDLogin.Saved(email: address, password: password)
                password = ""
                if !faceIDSaved, FaceIDLogin.biometryName != nil {
                    offerFaceID = saved
                } else {
                    if faceIDSaved { _ = FaceIDLogin.save(saved, for: model.serverURL) }
                    model.enterApp()
                }
            } catch {
                let apiError = error as? APIError
                errorMessage = apiError?.message ?? "Could not sign in. Try again."
                needsConfirmation = apiError?.flags["emailUnverified"] == true
            }
            working = false
        }
    }

    /// Carry on from a new account: sign straight in when nothing is waiting,
    /// otherwise say what is.
    private func accountCreated(email address: String, password secret: String, result: SignupResult) {
        email = address
        errorMessage = nil
        needsConfirmation = false
        if !result.verificationRequired && !result.approvalRequired {
            signupNote = nil
            password = secret
            submit()
            return
        }
        var steps: [String] = []
        if result.verificationRequired {
            steps.append(result.emailSent
                ? "Account created. Open the link we sent to \(result.email) to confirm your address."
                : "Account created, but the confirmation email could not be sent. Send it again below.")
            needsConfirmation = true
        }
        if result.approvalRequired {
            steps.append(result.verificationRequired
                ? "A dispatcher also needs to approve your account."
                : "Account created. A dispatcher needs to approve it before you can sign in.")
        }
        signupNote = steps.joined(separator: " ")
    }

    private func finish(keeping saved: FaceIDLogin.Saved?) {
        if let saved { _ = FaceIDLogin.save(saved, for: model.serverURL) }
        offerFaceID = nil
        model.enterApp()
    }

    private func signInWithFaceID() {
        guard !working else { return }
        working = true
        errorMessage = nil
        Task {
            defer { working = false }
            guard let saved = await FaceIDLogin.read(for: model.serverURL) else {
                // Cancelled, or the enrolled faces changed and the details went with them.
                faceIDSaved = FaceIDLogin.isSaved(for: model.serverURL)
                return
            }
            email = saved.email
            do {
                try await model.verifyCredentials(email: saved.email, password: saved.password)
                model.enterApp()
            } catch {
                let apiError = error as? APIError
                if apiError?.status == 401 {
                    FaceIDLogin.forget(for: model.serverURL)
                    faceIDSaved = false
                    errorMessage = "Your password has changed. Sign in with it once to turn \(FaceIDLogin.biometryName ?? "Face ID") back on."
                } else {
                    errorMessage = apiError?.message ?? "Could not sign in. Try again."
                }
            }
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
