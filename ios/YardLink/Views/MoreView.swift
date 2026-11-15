import SwiftUI

struct MoreView: View {
    @EnvironmentObject private var model: AppModel
    let user: SessionUser
    @State private var confirmingDisconnect = false

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
            .navigationTitle("More")
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
}
