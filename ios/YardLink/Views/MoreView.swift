import SwiftUI

struct MoreView: View {
    @EnvironmentObject private var model: AppModel
    let user: SessionUser
    @State private var confirmingDisconnect = false
    @State private var emailTopics: [String] = []
    @State private var emailPrefs: [String: Bool] = [:]
    @State private var emailAvailable = true
    @State private var savingTopic: String?
    @State private var emailError: String?

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Account") {
                    LabeledContent("Name", value: user.fullName)
                    LabeledContent("Role", value: user.roleLabel)
                    LabeledContent("Email", value: user.email)
                    NavigationLink {
                        AccountSettingsView(user: user)
                    } label: {
                        Label("Account Settings", systemImage: "person.crop.circle")
                    }
                }
                if !emailTopics.isEmpty {
                    Section {
                        ForEach(emailTopics, id: \.self) { topic in
                            Toggle(isOn: emailBinding(for: topic)) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(Self.topicLabel(topic))
                                    Text(Self.topicHint(topic))
                                        .font(.caption)
                                        .foregroundColor(Brand.muted)
                                }
                            }
                            .disabled(savingTopic != nil)
                        }
                        if let emailError {
                            Text(emailError)
                                .font(.footnote)
                                .foregroundColor(Brand.danger)
                        }
                    } header: {
                        Text("Email Me About")
                    } footer: {
                        Text(emailAvailable
                            ? "Work, messages and account news always show up in Yard Link. Turn on email to get a copy at \(user.email) as well."
                            : "Your company has not set up email in Yard Link yet, so nothing is emailed. Your choices are saved for when it is.")
                    }
                }
                Section("Employer") {
                    LabeledContent("Company", value: user.companyName)
                    if let server = model.serverURL {
                        LabeledContent("Server", value: server.host ?? server.absoluteString)
                        Link(destination: server) {
                            Label("Open Yard Link on the web", systemImage: "safari")
                        }
                    }
                }
                Section {
                    Button("Sign Out") {
                        Task { await model.signOut() }
                    }
                    Button("Disconnect From Employer", role: .destructive) {
                        confirmingDisconnect = true
                    }
                } footer: {
                    Text("Yard Link \(version)")
                }
            }
            .scrollContentBackground(.hidden)
            .screenBackground()
            .navigationTitle("More")
            .navigationBarTitleDisplayMode(.inline)
            .navyBar()
            .task { await loadEmailPrefs() }
            .confirmationDialog(
                "Disconnect from \(user.companyName)?",
                isPresented: $confirmingDisconnect,
                titleVisibility: .visible
            ) {
                Button("Disconnect", role: .destructive) { model.disconnect() }
                Button("Stay Connected", role: .cancel) {}
            } message: {
                Text("You will be signed out and will need to scan an employer code again.")
            }
        }
    }

    // MARK: Email copies

    private static func topicLabel(_ topic: String) -> String {
        switch topic {
        case "assignments": return "Work assignments"
        case "messages": return "New messages"
        case "signups": return "New accounts to approve"
        default: return topic.capitalized
        }
    }

    private static func topicHint(_ topic: String) -> String {
        switch topic {
        case "assignments": return "When dispatch assigns or changes your work for a day."
        case "messages": return "When someone writes to you and you have not read it yet."
        case "signups": return "When someone signs up and is waiting for a dispatcher."
        default: return ""
        }
    }

    private func emailBinding(for topic: String) -> Binding<Bool> {
        Binding(
            get: { emailPrefs[topic] ?? false },
            set: { wanted in Task { await setEmail(topic, wanted) } }
        )
    }

    private func loadEmailPrefs() async {
        guard let api = model.api else { return }
        do {
            let account: AccountInfo = try await api.get("/api/account")
            emailTopics = account.notifications.emailTopics
            emailPrefs = account.notifications.emailPrefs
            emailAvailable = account.notifications.emailAvailable
        } catch {
            _ = model.handle(error)
        }
    }

    /// Saves one switch. It goes back to where it was if the server says no,
    /// so the screen never shows a choice that was not saved.
    private func setEmail(_ topic: String, _ wanted: Bool) async {
        guard let api = model.api, savingTopic == nil else { return }
        let before = emailPrefs[topic] ?? false
        savingTopic = topic
        emailError = nil
        emailPrefs[topic] = wanted
        do {
            let result: EmailPrefsResult = try await api.patch("/api/account/email-prefs", body: [topic: wanted])
            emailPrefs = result.prefs
        } catch {
            emailPrefs[topic] = before
            emailError = model.handle(error)
        }
        savingTopic = nil
    }
}
