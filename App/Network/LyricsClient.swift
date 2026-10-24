import Foundation

/// Sends the lyrics requests over a default session with a 10 second request timeout.
nonisolated struct LyricsClient: Sendable {
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        session = URLSession(configuration: config)
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}
