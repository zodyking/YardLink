import AppIntents
import Foundation

/// Siri and the Shortcuts app: "Send a message to dispatch with Yard Link."
///
/// The intent runs in the app's own process, which may not have a screen up,
/// so it reads the connected server itself rather than going through the
/// model. The sign-in is the same cookie the app uses.
@available(iOS 16.0, *)
struct SendDispatchMessageIntent: AppIntent {
    static var title: LocalizedStringResource = "Send a Message to Dispatch"
    static var description = IntentDescription(
        "Sends a message to your dispatcher in Yard Link, without opening the app."
    )
    /// Nothing to look at: the answer is spoken, or shown in Shortcuts.
    static var openAppWhenRun = false

    @Parameter(title: "Message", requestValueDialog: "What should dispatch know?")
    var message: String

    init() {}

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return .result(dialog: "There was nothing to send.")
        }
        guard let api = SiriSession.client() else {
            return .result(dialog: "Open Yard Link and connect to your employer first.")
        }
        struct Outgoing: Encodable {
            let body: String
            let kind = "TEXT"
        }
        do {
            let _: SiriSession.Sent = try await api.post("/api/messages/dispatch", body: Outgoing(body: text))
            return .result(dialog: "Sent to dispatch.")
        } catch let error as APIError {
            if error.isSignedOut {
                return .result(dialog: "Open Yard Link and sign in first.")
            }
            return .result(dialog: "Yard Link would not send that. Open the app to see why.")
        } catch {
            return .result(dialog: "Could not reach your Yard Link server.")
        }
    }
}

/// The phrases Siri listens for. They all name the app, as Apple requires.
@available(iOS 16.4, *)
struct YardLinkShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SendDispatchMessageIntent(),
            phrases: [
                "Send a message to dispatch with \(.applicationName)",
                "Message dispatch with \(.applicationName)",
                "Tell dispatch with \(.applicationName)",
                "Send a \(.applicationName) message to dispatch",
            ],
            shortTitle: "Message Dispatch",
            systemImageName: "bubble.left.and.bubble.right.fill"
        )
    }
}

/// The connected server, read the way the app saves it.
enum SiriSession {
    struct Sent: Decodable {
        let threadId: String?
    }

    static func client() -> APIClient? {
        guard let saved = UserDefaults.standard.string(forKey: StoredKeys.server),
              let url = URL(string: saved) else { return nil }
        return APIClient(baseURL: url)
    }
}
