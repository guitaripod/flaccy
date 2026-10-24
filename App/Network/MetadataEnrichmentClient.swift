import Foundation

/// Sends the metadata enrichment requests (MusicBrainz, Cover Art Archive and Deezer) over a default session with a 15 second request timeout and Flaccy's `User-Agent`.
nonisolated struct MetadataEnrichmentClient: Sendable {
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.httpAdditionalHeaders = [
            "User-Agent": "flaccy/1.0 (https://github.com/guitaripod/flaccy)"
        ]
        session = URLSession(configuration: config)
    }

    func data(from url: URL) async throws -> (Data, URLResponse) {
        try await session.data(from: url)
    }
}
