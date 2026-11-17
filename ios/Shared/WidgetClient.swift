import Foundation

/// The few calls a widget makes, with the same session cookie the app holds.
/// Kept apart from the app's own client so the widget carries none of the app.
struct WidgetClient {
    struct Failure: Error {
        let signedOut: Bool
    }

    let base: URL
    private let session: URLSession

    init?(base: URL? = SharedStore.serverURL) {
        guard let base else { return nil }
        self.base = base
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = SharedStore.cookies
        configuration.httpShouldSetCookies = true
        configuration.timeoutIntervalForRequest = 15
        session = URLSession(configuration: configuration)
    }

    private func send(_ method: String, _ path: String, body: Data? = nil) async throws -> Data {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Failure(signedOut: status == 401) }
        return data
    }

    // MARK: Tasks

    private struct TaskRows: Decodable {
        struct Row: Decodable {
            let id: String
            let title: String?
            let rawText: String?
            let kind: String?
            let status: String
        }
        let tasks: [Row]
    }

    /// Open work, then what was finished today, as the Tasks screen orders it.
    func tasks() async throws -> [WidgetTask] {
        let rows = try JSONDecoder().decode(TaskRows.self, from: try await send("GET", "api/tasks")).tasks
        return rows
            .filter { $0.status != "DISMISSED" && $0.status != "DRAFT" }
            .map { row in
                let fallback = (row.kind ?? "Task").replacingOccurrences(of: "_", with: " ").capitalized
                let name = [row.title, row.rawText].compactMap { $0 }.first { !$0.isEmpty } ?? fallback
                return WidgetTask(id: row.id, title: name, done: row.status == "DONE")
            }
    }

    func setTask(_ id: String, done: Bool) async throws {
        struct Body: Encodable { let status: String }
        _ = try await send("PATCH", "api/tasks/\(id)", body: try JSONEncoder().encode(Body(status: done ? "DONE" : "OPEN")))
    }

    // MARK: Trip

    private struct Home: Decodable {
        struct Place: Decodable { let name: String? }
        struct Box: Decodable { let number: String? }
        struct Chassis: Decodable { let number: String? }
        struct Trip: Decodable { let status: String }
        struct Step: Decodable { let label: String? }
        struct Active: Decodable {
            let trip: Trip
            let container: Box?
            let chassis: Chassis?
            let destination: Place?
            let primaryAction: Step?
        }
        let active: Active?
        let recentCompleted: Active?
    }

    func trip() async throws -> WidgetTrip? {
        let home = try JSONDecoder().decode(Home.self, from: try await send("GET", "api/home"))
        guard let shown = home.active ?? home.recentCompleted else { return nil }
        return WidgetTrip(
            container: shown.container?.number,
            chassis: shown.chassis?.number,
            destination: shown.destination?.name,
            status: shown.trip.status,
            next: shown.primaryAction?.label,
            live: home.active != nil
        )
    }
}
