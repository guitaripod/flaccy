import Foundation

/// Fetches the bytes of a remote image over the shared URL session. Callers check the status, decode and cache the image themselves.
nonisolated struct RemoteImageClient: Sendable {
    func data(from url: URL) async throws -> (Data, URLResponse) {
        try await URLSession.shared.data(from: url)
    }

    func load(from url: URL, completion: @escaping @Sendable (Data?) -> Void) {
        URLSession.shared.dataTask(with: url) { data, _, _ in completion(data) }.resume()
    }
}
