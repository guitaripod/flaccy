import Foundation

/// Reads the public iTunes Search API over the shared URL session. Callers check the status and parse the JSON themselves.
nonisolated struct ITunesSearchClient: Sendable {
    func data(from url: URL) async throws -> (Data, URLResponse) {
        try await URLSession.shared.data(from: url)
    }
}
