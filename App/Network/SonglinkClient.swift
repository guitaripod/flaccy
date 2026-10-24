import Foundation

/// Sends the Songlink page requests over a default session with a 15 second request timeout.
nonisolated struct SonglinkClient: Sendable {
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        session = URLSession(configuration: config)
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}
