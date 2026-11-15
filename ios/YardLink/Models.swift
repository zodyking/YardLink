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

// MARK: - Home

struct HomePayload: Decodable {
    struct Driver: Decodable {
        let firstName: String
        let company: String
    }

    struct Named: Decodable {
        let name: String?
        let number: String?
    }

    struct Trip: Decodable {
        let id: String
        let reference: String?
        let status: String
        let isLoaded: Bool?
        let sealNumber: String?
        let kind: String?
    }

    struct Active: Decodable {
        let trip: Trip
        let container: Named?
        let chassis: Named?
        let origin: Named?
        let destination: Named?
    }

    struct TodayTask: Decodable, Identifiable {
        let id: String
        let title: String?
        let status: String?
    }

    let driver: Driver
    let todayIso: String?
    let active: Active?
    let swapPartner: Active?
    let todayTasks: [TodayTask]?
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
