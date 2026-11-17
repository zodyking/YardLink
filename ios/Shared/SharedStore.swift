import Foundation

/// What the app and its widgets both need to see: which employer's server to
/// ask, the signed-in session, and the last tasks and trip fetched. The two
/// live in different processes, so everything shared goes through one App
/// Group container.
enum SharedStore {
    static let groupId = "group.com.zodyking.yardlink"

    private static var defaults: UserDefaults? { UserDefaults(suiteName: groupId) }

    /// Whether this build was signed with the App Group. Without it the app
    /// keeps working on its own and the widgets simply have nothing to show.
    static var groupAvailable: Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupId) != nil
    }

    /// The sign-in cookie, in a store the widgets can read too.
    static var cookies: HTTPCookieStorage {
        groupAvailable ? HTTPCookieStorage.sharedCookieStorage(forGroupContainerIdentifier: groupId) : .shared
    }

    /// Move a session saved before widgets existed into the shared store, so
    /// nobody has to sign in again.
    static func adoptOldSession(for server: URL) {
        guard groupAvailable, let old = HTTPCookieStorage.shared.cookies(for: server), !old.isEmpty else { return }
        for cookie in old {
            cookies.setCookie(cookie)
            HTTPCookieStorage.shared.deleteCookie(cookie)
        }
    }

    static var serverURL: URL? {
        get { defaults?.string(forKey: "server").flatMap(URL.init(string:)) }
        set {
            if let newValue { defaults?.set(newValue.absoluteString, forKey: "server") }
            else { defaults?.removeObject(forKey: "server") }
        }
    }

    // MARK: Snapshot

    static func loadSnapshot() -> WidgetSnapshot {
        guard let data = defaults?.data(forKey: "snapshot"),
              let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
        else { return WidgetSnapshot() }
        return snapshot
    }

    static func save(_ snapshot: WidgetSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults?.set(data, forKey: "snapshot")
    }

    static func clearSnapshot() {
        defaults?.removeObject(forKey: "snapshot")
        defaults?.removeObject(forKey: "pending")
    }

    // MARK: Changes made on a widget that the server has not heard yet

    static func pendingChanges() -> [PendingTaskChange] {
        guard let data = defaults?.data(forKey: "pending"),
              let list = try? JSONDecoder().decode([PendingTaskChange].self, from: data)
        else { return [] }
        return list
    }

    static func queue(_ change: PendingTaskChange) {
        var list = pendingChanges().filter { $0.taskId != change.taskId }
        list.append(change)
        savePending(list)
    }

    static func savePending(_ list: [PendingTaskChange]) {
        if list.isEmpty { defaults?.removeObject(forKey: "pending") }
        else if let data = try? JSONEncoder().encode(list) { defaults?.set(data, forKey: "pending") }
    }
}

struct WidgetTask: Codable, Identifiable, Hashable {
    let id: String
    var title: String
    var done: Bool
}

struct WidgetTrip: Codable, Hashable {
    var container: String?
    var chassis: String?
    var destination: String?
    var status: String
    /// What the driver does next, in the app's words ("Arrive", "Set drop-off").
    var next: String?
    var live: Bool

    var equipment: String {
        [container, chassis].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " on ")
    }

    var statusText: String {
        switch status {
        case "PICKUP_IN_PROGRESS": return "Picking up"
        case "IN_TRANSIT": return "In transit"
        case "DROPOFF_IN_PROGRESS": return "Dropping off"
        case "DROPPED_OFF", "COMPLETED": return "Dropped off"
        default: return status.capitalized
        }
    }
}

struct WidgetSnapshot: Codable {
    var updatedAt: Date?
    var signedIn = false
    var tasks: [WidgetTask] = []
    var trip: WidgetTrip?
}

struct PendingTaskChange: Codable, Hashable {
    let taskId: String
    let done: Bool
}
