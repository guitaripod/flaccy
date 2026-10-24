import Foundation

/// Downloads artist photos over one ephemeral session shared by the iOS and Mac artist image services, with a 15 second request timeout and a 30 second resource timeout.
nonisolated struct ArtistImageClient: Sendable {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    func data(from url: URL) async throws -> (Data, URLResponse) {
        try await Self.session.data(from: url)
    }
}
