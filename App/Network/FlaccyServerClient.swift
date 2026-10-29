import FlaccyCore
import Foundation

/// The HTTP client for one Flaccy Server (docs/server/PROTOCOL.md). Network code for the server lives here and nowhere else.
///
/// Every authenticated call carries the device token as a bearer token and, once known, the incarnation the client last
/// saw. Responses may arrive gzip or br compressed: URLSession advertises both and decompresses them. Request bodies go
/// out plain, because the server decompresses nothing it receives. The token and the enrollment code are never logged.
actor FlaccyServerClient: ServerSyncTransport {

    static let apiPath = "/flaccy/v1"
    static let protocolVersion = "1"
    static let probeTimeout: TimeInterval = 5
    static let callTimeout: TimeInterval = 60
    static let liveTimeout: TimeInterval = 15

    private let baseURL: URL
    private let token: String?
    private let session: URLSession

    init(baseURL: URL, token: String?, session: URLSession = FlaccyServerClient.makeSession()) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    nonisolated static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = callTimeout
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }

    func hello() async throws -> ServerHello {
        do {
            return try await decode(ServerHello.self, from: request("GET", "/hello", timeout: Self.probeTimeout))
        } catch ServerSyncError.malformed {
            throw ServerSyncError.notAFlaccyServer
        } catch ServerSyncError.refused(let status, _) where status == 404 || status == 405 {
            throw ServerSyncError.notAFlaccyServer
        }
    }

    func enroll(_ body: ServerEnrollRequest) async throws -> ServerEnrollReply {
        var call = try request("POST", "/devices", timeout: Self.probeTimeout)
        call.httpBody = try JSONEncoder().encode(body)
        call.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await decode(ServerEnrollReply.self, from: call)
    }

    func push(_ body: ServerPushRequest, incarnation: String?) async throws -> ServerPushResponse {
        var call = try request("POST", "/sync/push", incarnation: incarnation)
        call.httpBody = try JSONEncoder().encode(body)
        call.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await decode(ServerPushResponse.self, from: call)
    }

    func pull(since: Int64, limit: Int, instance: String, incarnation: String?) async throws -> ServerPullResponse {
        let query = [
            URLQueryItem(name: "since", value: String(since)),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "instance", value: instance),
        ]
        return try await decode(
            ServerPullResponse.self, from: request("GET", "/sync/pull", query: query, incarnation: incarnation)
        )
    }

    func listens(before: Int64?, after: Int64?, limit: Int, incarnation: String?) async throws -> ServerListensPage {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let before { query.append(URLQueryItem(name: "before", value: String(before))) }
        if let after { query.append(URLQueryItem(name: "after", value: String(after))) }
        return try await decode(
            ServerListensPage.self, from: request("GET", "/listens", query: query, incarnation: incarnation)
        )
    }

    func devices() async throws -> [ServerDevice] {
        try await decode(ServerDevicesReply.self, from: request("GET", "/devices")).devices
    }

    func renameDevice(id: String, name: String) async throws {
        var call = try request("PATCH", "/devices/\(Self.escaped(id))")
        call.httpBody = try JSONEncoder().encode(["name": name])
        call.setValue("application/json", forHTTPHeaderField: "Content-Type")
        _ = try await send(call)
    }

    func revokeDevice(id: String) async throws {
        _ = try await send(request("DELETE", "/devices/\(Self.escaped(id))"))
    }

    func putBlob(hash: String, data: Data, mime: String) async throws {
        var call = try request("PUT", "/blobs/\(Self.escaped(hash))")
        call.httpBody = data
        call.setValue(mime, forHTTPHeaderField: "Content-Type")
        _ = try await send(call)
    }

    func blob(hash: String) async throws -> Data {
        var call = try request("GET", "/blobs/\(Self.escaped(hash))")
        call.setValue("image/*", forHTTPHeaderField: "Accept")
        return try await send(call)
    }

    /// The WebSocket of `GET /live` (PROTOCOL.md section 9), signed in with the device token. The upgrade carries no `Origin`
    /// header, which the server refuses.
    func liveSocket(incarnation: String? = nil) throws -> URLSessionWebSocketTask {
        var call = try request("GET", "/live", incarnation: incarnation, timeout: Self.liveTimeout)
        guard let url = call.url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw ServerSyncError.malformed("the server address")
        }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        call.url = components.url
        call.setValue(nil, forHTTPHeaderField: "Accept")
        return session.webSocketTask(with: call)
    }

    private nonisolated static func escaped(_ segment: String) -> String {
        segment.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? segment
    }

    private func request(
        _ method: String, _ path: String, query: [URLQueryItem] = [], incarnation: String? = nil,
        timeout: TimeInterval = FlaccyServerClient.callTimeout
    ) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ServerSyncError.malformed("the server address")
        }
        components.path = Self.apiPath + path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw ServerSyncError.malformed("the server address") }
        var call = URLRequest(url: url, timeoutInterval: timeout)
        call.httpMethod = method
        call.setValue(Self.protocolVersion, forHTTPHeaderField: "Flaccy-Protocol")
        call.setValue("application/json", forHTTPHeaderField: "Accept")
        if let incarnation { call.setValue(incarnation, forHTTPHeaderField: "Flaccy-Incarnation") }
        if let token { call.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return call
    }

    private func decode<T: Decodable>(_ type: T.Type, from call: URLRequest) async throws -> T {
        let data = try await send(call)
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ServerSyncError.malformed(String(describing: type))
        }
    }

    private func send(_ call: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: call)
        } catch let error as URLError {
            throw Self.failure(of: error)
        }
        guard let http = response as? HTTPURLResponse else { throw ServerSyncError.malformed("not an HTTP answer") }
        guard (200..<300).contains(http.statusCode) else {
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap { Int($0) }
            throw ServerSyncError.from(
                status: http.statusCode, body: try? JSONDecoder().decode(ServerErrorBody.self, from: data),
                retryAfterSeconds: retryAfter
            )
        }
        return data
    }

    nonisolated static func failure(of error: URLError) -> Error {
        switch error.code {
        case .cancelled: CancellationError()
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .callIsActive: ServerSyncError.noNetwork
        case .timedOut: ServerSyncError.timedOut
        case .cannotFindHost, .dnsLookupFailed: ServerSyncError.nameNotFound
        case .badServerResponse, .cannotParseResponse, .zeroByteResource: ServerSyncError.malformed("not an HTTP answer")
        default: ServerSyncError.offline(error.localizedDescription)
        }
    }
}

/// Makes the URLSession client for a server.
nonisolated struct FlaccyServerTransports: ServerSyncTransportFactory {
    func transport(baseURL: URL, token: String?) -> any ServerSyncTransport {
        FlaccyServerClient(baseURL: baseURL, token: token)
    }
}
