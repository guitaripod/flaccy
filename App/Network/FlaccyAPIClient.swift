import Foundation
import MidgarCore

/// Flaccy's own server, flaccy-api, reached through the Midgar gateway: every path here is sent to
/// `https://api.midgarcorp.cc/v1/flaccy/<path>`, which the gateway forwards to the worker with its headers. The AI
/// metadata proxy, Last.fm signing and the sample album all live behind it.
nonisolated struct FlaccyAPIClient: Sendable {
    static let service = "flaccy"

    /// The mount point of flaccy-api behind the gateway: `/v1/flaccy`, with the worker's own `v1/...` paths below it.
    private static let mountPath = "v1/\(service)"

    /// The id the worker rate-limits by and the only identity the AI proxy and the signer ask for. It is a random
    /// UUID kept in `UserDefaults`, not the Midgar ID.
    static let deviceIdentifier: String = {
        let key = "flaccy.deviceIdentifier"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }()

    private let baseURL: URL
    private let appID: String
    private let http: MidgarHTTPClient
    private let aiSession: URLSession

    init(baseURL: URL = MidgarHTTPConfiguration.defaultBaseURL, appID: String = FlaccyMidgar.appID) {
        self.baseURL = baseURL
        self.appID = appID
        http = MidgarHTTPClient(configuration: MidgarHTTPConfiguration(baseURL: baseURL, appID: appID))
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        aiSession = URLSession(configuration: configuration)
    }

    /// The gateway address of a flaccy-api path such as `v1/samples`.
    func url(path: String) -> URL {
        baseURL.appendingPathComponent("\(Self.mountPath)/\(path)")
    }

    /// A GET for a flaccy-api path that streams or downloads, carrying the `X-App-ID` the gateway requires.
    func downloadRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(appID, forHTTPHeaderField: "X-App-ID")
        return request
    }

    /// What the AI proxy answered, whatever the status. The proxy's refusals carry the reason as a string `error`
    /// code and a `Retry-After`, which the job needs to tell a busy model from a spent daily allowance.
    struct ProxyReply: Sendable {
        let status: Int
        let body: Data
        let retryAfter: TimeInterval?
    }

    /// Posts a chat request to the AI metadata proxy. Throws the transport's error when nothing answered.
    func postMetadata(_ chatRequest: some Encodable & Sendable) async throws -> ProxyReply {
        var request = URLRequest(url: url(path: "v1/metadata"))
        request.httpMethod = "POST"
        request.setValue(appID, forHTTPHeaderField: "X-App-ID")
        request.setValue(Self.deviceIdentifier, forHTTPHeaderField: "X-Device-ID")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(chatRequest)
        let (body, response) = try await aiSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return ProxyReply(
            status: http.statusCode,
            body: body,
            retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
        )
    }

    private struct SignRequest: Encodable, Sendable {
        let params: [String: String]
    }

    private struct SignReply: Decodable, Sendable {
        let api_sig: String
    }

    /// Asks the worker for the `api_sig` of a Last.fm call, whose shared secret lives only on the worker.
    func lastFMSignature(for params: [String: String]) async throws(MidgarHTTPError) -> String {
        let reply: SignReply = try await http.send(MidgarRequest(
            service: Self.service,
            path: "v1/lastfm/sign",
            method: .post,
            headers: ["X-Device-ID": Self.deviceIdentifier],
            body: SignRequest(params: params)
        ))
        return reply.api_sig
    }
}
