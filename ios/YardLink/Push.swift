import Foundation
import UIKit
import UserNotifications

/// Push notifications: ask once, hand Apple's token to the server, and carry a
/// tapped notice to the screen it belongs to.
///
/// The server decides whether notices are sent at all — a dispatcher enters the
/// Apple key under Settings. The phone registers either way, so the moment the
/// key is entered every phone already signed in can be reached.
@MainActor
final class PushCenter: NSObject, ObservableObject {
    static let shared = PushCenter()

    /// Where a tapped notice wants to go: "messages", "tasks" or "home".
    @Published var openScreen: String?
    @Published var openThreadId: String?

    /// The token Apple last gave this phone, kept so sign-out can cancel it.
    private(set) var deviceToken: String?
    private var registered = false

    /// Development builds talk to Apple's sandbox; everything else does not.
    private var usesSandbox: Bool {
        #if DEBUG
        return true
        #else
        return Bundle.main.path(forResource: "embedded", ofType: "mobileprovision") != nil
        #endif
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    func start() {
        UNUserNotificationCenter.current().delegate = self
        ArrivalNotification.registerCategory()
    }

    /// Ask for permission, then register. Called once the person is signed in,
    /// so the question arrives with Yard Link already on screen.
    func askAndRegister() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            guard granted else { return }
        } else if settings.authorizationStatus == .denied {
            return
        }
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// Apple answered `registerForRemoteNotifications`.
    func received(token data: Data) {
        let token = data.map { String(format: "%02x", $0) }.joined()
        deviceToken = token
        Task { await send(token: token) }
    }

    /// Send the token again on every launch: Apple replaces it without warning.
    func refresh() {
        guard let token = deviceToken else { return }
        Task { await send(token: token) }
    }

    private func send(token: String) async {
        guard let api = AppModel.current?.api else { return }
        struct Device: Encodable {
            let token: String
            let sandbox: Bool
            let appVersion: String
        }
        let _: OkResult? = try? await api.post(
            "/api/devices/register",
            body: Device(token: token, sandbox: usesSandbox, appVersion: appVersion)
        )
        registered = true
    }

    /// Stop the notices to this phone on sign-out or disconnect.
    func forget() async {
        guard registered, let token = deviceToken, let api = AppModel.current?.api else { return }
        struct Device: Encodable { let token: String }
        let _: OkResult? = try? await api.post("/api/devices/unregister", body: Device(token: token))
        registered = false
    }

    func clearBadge() {
        UNUserNotificationCenter.current().setBadgeCount(0) { _ in }
    }
}

extension PushCenter: UNUserNotificationCenterDelegate {
    /// Yard Link is open: still show the notice, so nothing is missed.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    /// A tapped notice opens the screen it came from.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let screen = info["screen"] as? String
        let threadId = info["threadId"] as? String
        let arrivalId = info["arrivalId"] as? String
        let locationName = info["locationName"] as? String ?? "this stop"
        let action = response.actionIdentifier
        Task { @MainActor in
            let center = PushCenter.shared
            center.clearBadge()

            // "Yes, I'm here" and "Not yet" are answered without opening the app.
            if let arrivalId, action == ArrivalNotification.arrived || action == ArrivalNotification.notYet {
                let question = ArrivalQuestion(
                    id: arrivalId,
                    locationName: locationName,
                    enteredAt: "",
                    autoAt: ""
                )
                await ArrivalWatch.shared.answer(question, arrived: action == ArrivalNotification.arrived)
                completionHandler()
                return
            }

            center.openThreadId = threadId
            center.openScreen = screen ?? "home"
            if screen == "arrival" { await ArrivalWatch.shared.refresh() }
            completionHandler()
        }
    }
}

/// Apple hands the device token to the app delegate and nowhere else.
final class PushAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        MainActor.assumeIsolated { PushCenter.shared.start() }
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        MainActor.assumeIsolated { PushCenter.shared.received(token: deviceToken) }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("[push] Apple would not register this phone: \(error.localizedDescription)")
    }
}
