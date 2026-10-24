import Foundation

/// Sends the Last.fm API requests over a default session with a 15 second request timeout. Signing is not here: `FlaccyAPIClient` asks flaccy-api for the signature before a request reaches this client.
nonisolated struct LastFMClient: Sendable {
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        session = URLSession(configuration: config)
    }

    func data(from url: URL) async throws -> (Data, URLResponse) {
        try await session.data(from: url)
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}
