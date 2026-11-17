import Foundation
import SwiftUI

/// Where the connected server is kept. The Siri intent reads the same key,
/// and it runs without the app's model.
enum StoredKeys {
    static let server = "yardlink.server"
    static let employerName = "yardlink.employerName"
}

/// Where the app is in its one fixed sequence:
/// Connect to Your Employer → Sign In → Yard Link.
@MainActor
final class AppModel: ObservableObject {
    enum Stage: Equatable {
        case launching
        case connect
        case signIn
        case ready(SessionUser)
    }

    @Published private(set) var stage: Stage = .launching
    @Published private(set) var employerName: String = ""
    @Published private(set) var serverURL: URL?
    @Published var connectError: String?
    @Published var isConnecting = false
    @Published var unreadMessages = 0

    private(set) var api: APIClient?

    /// The one model the app runs on, so the push layer can reach the server
    /// without being handed down through every screen.
    static private(set) weak var current: AppModel?

    private let defaults = UserDefaults.standard
    private let serverKey = StoredKeys.server
    private let nameKey = StoredKeys.employerName

    init() {
        AppModel.current = self
        if let saved = defaults.string(forKey: serverKey), let url = URL(string: saved) {
            serverURL = url
            employerName = defaults.string(forKey: nameKey) ?? ""
            api = APIClient(baseURL: url)
        }
    }

    /// Decide the first screen: connected and signed in, connected only, or neither.
    func start() async {
        guard let api else {
            stage = .connect
            return
        }
        do {
            let session: SessionEnvelope = try await api.get("/api/_auth/session")
            if let user = session.user {
                stage = .ready(user)
            } else {
                stage = .signIn
            }
        } catch {
            // Offline at launch: keep the employer, ask to sign in when back.
            stage = .signIn
        }
    }

    // MARK: Connect

    /// Scanned QR text, a tapped link, or an address typed by hand.
    func handleConnectText(_ text: String) {
        guard let target = ConnectTarget.parse(text) else {
            connectError = "That is not a Yard Link connection code. Ask your dispatcher to show the code from Settings."
            return
        }
        Task { await connect(to: target) }
    }

    func connect(to target: ConnectTarget) async {
        guard !isConnecting else { return }
        isConnecting = true
        connectError = nil
        defer { isConnecting = false }

        let candidate = APIClient(baseURL: target.server)
        do {
            let info: ConnectInfo = try await candidate.get("/api/connect")
            guard info.app == "yardlink" else {
                connectError = "That address is not a Yard Link server."
                return
            }
            guard info.ready else {
                connectError = "This Yard Link server has not finished setup yet. Ask your dispatcher to open it in a browser first."
                return
            }
            let name = info.companyName ?? target.name
            defaults.set(target.server.absoluteString, forKey: serverKey)
            defaults.set(name, forKey: nameKey)
            serverURL = target.server
            employerName = name
            api = candidate
            stage = .signIn
        } catch {
            connectError = (error as? APIError)?.message ?? "Could not reach that server. Try again."
        }
    }

    /// Forget this employer entirely and go back to the first screen.
    func disconnect() {
        Task { await PushCenter.shared.forget() }
        FaceIDLogin.forget(for: serverURL)
        api?.clearCookies()
        defaults.removeObject(forKey: serverKey)
        defaults.removeObject(forKey: nameKey)
        api = nil
        serverURL = nil
        employerName = ""
        unreadMessages = 0
        stage = .connect
    }

    // MARK: Session

    /// The signed-in person, held until the sign-in screen is done asking
    /// whether to keep the details behind Face ID.
    private var pendingUser: SessionUser?

    /// Sign in with the server. The app opens on `enterApp()`, so the sign-in
    /// screen can ask one more question first.
    func verifyCredentials(email: String, password: String) async throws {
        guard let api else { return }
        struct Credentials: Encodable { let email: String; let password: String }
        let _: LoginResult = try await api.post("/api/auth/login", body: Credentials(email: email, password: password))
        let session: SessionEnvelope = try await api.get("/api/_auth/session")
        guard let user = session.user else {
            throw APIError(status: 0, message: "Signed in, but the session did not start. Try again.", flags: [:])
        }
        pendingUser = user
    }

    func enterApp() {
        guard let user = pendingUser else { return }
        pendingUser = nil
        stage = .ready(user)
    }

    /// Read the session again after the person changed their name or email,
    /// so every screen shows the new one.
    func reloadSession() async {
        guard let api, case .ready = stage,
              let session: SessionEnvelope = try? await api.get("/api/_auth/session"),
              let user = session.user else { return }
        stage = .ready(user)
    }

    /// Ask the server to send the welcome email again. Always answers with
    /// a sentence to show under the button.
    func resendConfirmation(email: String) async -> String {
        guard let api else { return "Connect to your employer first." }
        struct Address: Encodable { let email: String }
        do {
            let result: MessageResult = try await api.post("/api/auth/resend-verification", body: Address(email: email))
            return result.message
        } catch {
            return (error as? APIError)?.message ?? "Could not send the email. Try again in a minute."
        }
    }

    func signOut() async {
        await PushCenter.shared.forget()
        if let api {
            let _: OkResult? = try? await api.post("/api/auth/logout")
            api.clearCookies()
        }
        unreadMessages = 0
        stage = .signIn
    }

    /// Any screen that gets a 401 calls this so the app returns to sign-in.
    func handle(_ error: Error) -> String {
        if let apiError = error as? APIError {
            if apiError.isSignedOut { stage = .signIn }
            return apiError.message
        }
        return "Something went wrong. Try again."
    }

    /// Tell the server where the phone is, for today's time card. Quiet on
    /// purpose: a missed ping must never show up as an error.
    func sendTimeCardPing() async {
        guard let api, case .ready = stage, let fix = await LocationFix.shared.current(timeoutSeconds: 12) else { return }
        let _: OkResult? = try? await api.post("/api/time-cards/ping", body: fix)
    }

    func refreshUnread() async {
        guard let api, case .ready = stage else { return }
        if let count: UnreadCount = try? await api.get("/api/messages/unread") {
            unreadMessages = count.unread
        }
    }
}
