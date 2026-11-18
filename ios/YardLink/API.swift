import Foundation

/// A failure worth showing to the person, in words they can act on.
struct APIError: LocalizedError {
    let status: Int
    let message: String
    /// Extra flags the server attaches, e.g. `approvalPending`.
    let flags: [String: Bool]
    /// Extra references the server attaches, e.g. the `tripId` already in progress.
    var details: [String: String] = [:]

    var errorDescription: String? { message }
    var isSignedOut: Bool { status == 401 }
}

private struct ServerErrorBody: Decodable {
    let statusMessage: String?
    let message: String?
    let data: [String: FlagValue]?

    /// Booleans and short references matter to the app; anything else is ignored.
    enum FlagValue: Decodable {
        case bool(Bool)
        case text(String)
        case other

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Bool.self) {
                self = .bool(value)
            } else if let value = try? container.decode(String.self) {
                self = .text(value)
            } else {
                self = .other
            }
        }
    }
}

/// Talks to the employer's Yard Link server. The phone keeps no business
/// rules of its own: it sends what the person did and shows what the server
/// answers. The session is the same cookie the web app uses, held by the
/// system cookie store, so signing in once lasts across launches.
final class APIClient {
    let baseURL: URL
    private let session: URLSession
    /// Same cookies, three minutes of patience.
    private let patientSession: URLSession
    private let decoder: JSONDecoder
    private let encoder = JSONEncoder()

    init(baseURL: URL) {
        self.baseURL = baseURL

        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = SharedStore.cookies
        configuration.httpShouldSetCookies = true
        configuration.timeoutIntervalForRequest = 30
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)

        let patient = URLSessionConfiguration.default
        patient.httpCookieStorage = SharedStore.cookies
        patient.httpShouldSetCookies = true
        patient.timeoutIntervalForRequest = 180
        patientSession = URLSession(configuration: patient)

        SharedStore.adoptOldSession(for: baseURL)

        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = withFraction.date(from: text) ?? plain.date(from: text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unreadable date \(text)"))
        }
    }

    func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        try await send(method: "GET", path: path, query: query, body: Optional<Data>.none)
    }

    /// `patient` is for the few calls that take the server a while, such as
    /// reading a photo or saving a large file.
    func post<T: Decodable, Body: Encodable>(_ path: String, body: Body, patient: Bool = false) async throws -> T {
        try await send(method: "POST", path: path, query: [:], body: try encoder.encode(body), patient: patient)
    }

    func post<T: Decodable>(_ path: String) async throws -> T {
        try await send(method: "POST", path: path, query: [:], body: Data("{}".utf8))
    }

    func patch<T: Decodable, Body: Encodable>(_ path: String, body: Body) async throws -> T {
        try await send(method: "PATCH", path: path, query: [:], body: try encoder.encode(body))
    }

    func delete<T: Decodable>(_ path: String) async throws -> T {
        try await send(method: "DELETE", path: path, query: [:], body: Optional<Data>.none)
    }

    /// Address of a protected file (photo, document) for use with `data(for:)`.
    func url(_ path: String, query: [String: String] = [:]) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        components.path = path
        if !query.isEmpty {
            components.queryItems = query.sorted(by: { $0.key < $1.key }).map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return components.url ?? baseURL
    }

    func data(_ path: String, query: [String: String] = [:]) async throws -> Data {
        var request = URLRequest(url: url(path, query: query))
        request.httpMethod = "GET"
        let (data, response) = try await perform(request)
        try check(response, data)
        return data
    }

    /// Forget the session on this phone (after sign-out or disconnect).
    func clearCookies() {
        guard let cookies = SharedStore.cookies.cookies(for: baseURL) else { return }
        cookies.forEach { SharedStore.cookies.deleteCookie($0) }
    }

    private func send<T: Decodable>(method: String, path: String, query: [String: String], body: Data?, patient: Bool = false) async throws -> T {
        var request = URLRequest(url: url(path, query: query))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await perform(request, patient: patient)
        try check(response, data)
        do {
            return try decoder.decode(T.self, from: data.isEmpty ? Data("{}".utf8) : data)
        } catch {
            throw APIError(
                status: 0,
                message: "The server sent something this version of Yard Link does not understand"
                    + (Self.fieldAtFault(error).map { " (\($0))" } ?? "")
                    + ". Update the app, or tell your dispatcher.",
                flags: [:]
            )
        }
    }

    /// The field the decoder tripped on, as a path like `active.destination.latitude`,
    /// so a report from the road says what to fix instead of only that something broke.
    static func fieldAtFault(_ error: Error) -> String? {
        guard let decoding = error as? DecodingError else { return nil }
        let context: DecodingError.Context
        switch decoding {
        case let .typeMismatch(_, inner), let .valueNotFound(_, inner),
             let .keyNotFound(_, inner), let .dataCorrupted(inner):
            context = inner
        @unknown default:
            return nil
        }
        var path = context.codingPath.map(\.stringValue)
        if case let .keyNotFound(key, _) = decoding { path.append(key.stringValue) }
        let joined = path.filter { !$0.isEmpty }.joined(separator: ".")
        return joined.isEmpty ? nil : joined
    }

    private func perform(_ request: URLRequest, patient: Bool = false) async throws -> (Data, URLResponse) {
        do {
            return try await (patient ? patientSession : session).data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                throw APIError(status: 0, message: "No connection. Check your signal and try again.", flags: [:])
            case .timedOut:
                throw APIError(status: 0, message: "The server took too long to answer. Try again.", flags: [:])
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                throw APIError(status: 0, message: "Could not reach your employer's server. Check the address with your dispatcher.", flags: [:])
            case .appTransportSecurityRequiresSecureConnection, .secureConnectionFailed, .serverCertificateUntrusted:
                throw APIError(status: 0, message: "This server does not have a secure (https) address that iPhone accepts. Ask your dispatcher for the https address.", flags: [:])
            default:
                throw APIError(status: 0, message: "Could not reach the server. Try again.", flags: [:])
            }
        }
    }

    private func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard !(200..<300).contains(http.statusCode) else { return }
        let body = try? JSONDecoder().decode(ServerErrorBody.self, from: data)
        var flags: [String: Bool] = [:]
        var details: [String: String] = [:]
        for (key, value) in body?.data ?? [:] {
            switch value {
            case let .bool(flag): flags[key] = flag
            case let .text(text): details[key] = text
            case .other: break
            }
        }
        let fallback = http.statusCode >= 500
            ? "The server ran into a problem. Try again in a moment."
            : "That did not work. Try again."
        let message = [body?.statusMessage, body?.message].compactMap { $0 }.first(where: { !$0.isEmpty }) ?? fallback
        throw APIError(status: http.statusCode, message: message, flags: flags, details: details)
    }
}
