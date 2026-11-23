import Foundation

/// What the employer connection code carries: where the server is and what
/// to call it. Never a password.
struct ConnectTarget: Equatable {
    let server: URL
    let name: String

    /// Accepts `yardlink://connect?server=…&name=…`, or a server address typed by hand.
    static func parse(_ raw: String) -> ConnectTarget? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        var serverText = ""
        var name = ""
        if text.lowercased().hasPrefix("yardlink://") {
            guard let components = URLComponents(string: text) else { return nil }
            let items = components.queryItems ?? []
            serverText = items.first(where: { $0.name == "server" })?.value ?? ""
            name = items.first(where: { $0.name == "name" })?.value ?? ""
        } else {
            let lower = text.lowercased()
            serverText = (lower.hasPrefix("http://") || lower.hasPrefix("https://")) ? text : "https://\(text)"
        }

        guard let parsed = URLComponents(string: serverText),
              let scheme = parsed.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = parsed.host, !host.isEmpty else { return nil }

        var origin = URLComponents()
        origin.scheme = scheme
        origin.host = host
        origin.port = parsed.port
        guard let url = origin.url else { return nil }
        return ConnectTarget(server: url, name: name.trimmingCharacters(in: .whitespaces))
    }
}

struct ConnectInfo: Decodable {
    let app: String
    let apiVersion: Int
    let ready: Bool
    let companyName: String?
}

struct SessionUser: Decodable, Equatable {
    let userId: String
    let email: String
    let firstName: String
    let lastName: String
    let fullName: String
    let role: String
    let companyName: String

    var isDriver: Bool { role == "DRIVER" }
    var roleLabel: String { role == "ADMIN" ? "Dispatcher" : "Driver" }
}

struct SessionEnvelope: Decodable {
    let user: SessionUser?
}

struct LoginResult: Decodable {
    let ok: Bool
    let role: String
}

struct OkResult: Decodable {
    let ok: Bool?
}

/// A sentence from the server to show as is.
struct MessageResult: Decodable {
    let message: String
}

// MARK: - Account

/// The part of the account the phone shows: which topics this person can
/// also get by email, which are on, and whether the employer set up email.
struct AccountInfo: Decodable {
    struct Notifications: Decodable {
        let emailAvailable: Bool
        let emailTopics: [String]
        let emailPrefs: [String: Bool]
    }

    /// What a driver's time card is filled in from.
    struct DriverDetails: Decodable {
        let cdlNumber: String?
        let cdlState: String?
        let truckVin: String?
    }

    let firstName: String?
    let lastName: String?
    let email: String?
    let mobileNumber: String?
    let driver: DriverDetails?
    let notifications: Notifications
}

struct EmailPrefsResult: Decodable {
    let prefs: [String: Bool]
}

// MARK: - Home

struct HomePayload: Decodable {
    struct Driver: Decodable {
        let firstName: String?
        let company: String?
    }

    /// Today's counts shown at the top of Home.
    struct Stats: Decodable {
        let bridgeCrosses: Int?
        let swaps: Int?
    }

    struct Trip: Decodable {
        let id: String
        let reference: String?
        let status: String
        let isLoaded: Bool?
        let sealNumber: String?
        let kind: String?
        let swapPairTripId: String?
        let customer: String?
        /// When `recentCompleted` actually finished — the server keeps that
        /// field around for 12 hours so Home can still reference it, but the
        /// Live Activity only wants to say "done" for a few minutes, so it
        /// needs the real timestamp rather than just the field being present.
        let droppedOffAt: Date?
        let completedAt: Date?

        var isLive: Bool { ["PICKUP_IN_PROGRESS", "IN_TRANSIT", "DROPOFF_IN_PROGRESS"].contains(status) }
        var isBareChassis: Bool { kind == "BARE_CHASSIS" }
    }

    struct Box: Decodable {
        let id: String?
        let number: String?
        let containerType: String?
        let equipmentType: String?
    }

    /// The one thing to do next, as the server decides it. `to` is the web
    /// app's address for that step; the phone opens its own screen for it.
    struct NextStep: Decodable {
        let label: String?
        let to: String?
    }

    struct Active: Decodable {
        let trip: Trip
        let container: Box?
        let chassis: NumberedEquipment?
        let origin: NamedPlace?
        let destination: NamedPlace?
        let primaryAction: NextStep?
    }

    struct TodayTask: Decodable, Identifiable {
        let id: String
        let title: String?
        let status: String?
        let kind: String?
        let card: TaskCard?
    }

    let driver: Driver
    let stats: Stats?
    let todayIso: String?
    let active: Active?
    let swapPartner: Active?
    /// A trip finished in the last few hours, kept on Home until cleared.
    let recentCompleted: Active?
    let todayTasks: [TodayTask]?
    /// Whether the company has turned on Tools > Bridge Crossing Times.
    let bridgeCrossingTimesEnabled: Bool?
}

// MARK: - Messages

struct ThreadSummary: Decodable, Identifiable, Hashable {
    let id: String
    let kind: String
    let title: String
    let subtitle: String
    let lastMessageAt: Date?
    let lastMessagePreview: String?
    let unread: Int
}

struct ThreadList: Decodable {
    let threads: [ThreadSummary]
    let unread: Int
}

struct MessageFile: Decodable, Identifiable, Hashable {
    let id: String
    let fileName: String
    let mimeType: String?
}

struct ChatMessage: Decodable, Identifiable, Hashable {
    let id: String
    let senderUserId: String?
    let senderName: String
    let mine: Bool?
    let body: String
    let kind: String
    let tripId: String?
    let documents: [MessageFile]?
    let createdAt: Date

    var isSystem: Bool { senderUserId == nil }
    var kindLabel: String? {
        switch kind {
        case "TRIP_UPDATE": return "Trip update"
        case "TASKS": return "Work assigned"
        case "ACCOUNT": return "Account"
        default: return nil
        }
    }
}

struct ThreadMessages: Decodable {
    let threadId: String
    let messages: [ChatMessage]
}

struct SentMessage: Decodable {
    let message: ChatMessage
}

struct Contact: Decodable, Identifiable, Hashable {
    let userId: String
    let name: String
    let role: String
    var id: String { userId }
}

struct ContactList: Decodable {
    let contacts: [Contact]
}

struct ThreadRef: Decodable {
    let threadId: String
}

struct UnreadCount: Decodable {
    let unread: Int
}
