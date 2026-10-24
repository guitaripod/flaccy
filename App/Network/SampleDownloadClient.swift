import Foundation

/// Fetches the sample album over the shared URL session: the manifest, each file's size, and the file downloads with their resume data. The requests arrive built, with their headers, from `FlaccyAPIClient`.
nonisolated struct SampleDownloadClient: Sendable {
    func data(for request: URLRequest) async throws -> Data {
        try await URLSession.shared.data(for: request).0
    }

    /// Reads a file's size off the response headers and abandons the body unread, because the Worker answers HEAD without a length and ignores Range. Zero when the size cannot be read.
    func contentLength(for request: URLRequest) async -> Int64 {
        guard let (bytes, response) = try? await URLSession.shared.bytes(for: request) else { return 0 }
        bytes.task.cancel()
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return 0 }
        return max(response.expectedContentLength, 0)
    }

    func download(for request: URLRequest, capture: DownloadTaskCapture) async throws -> (URL, URLResponse) {
        try await URLSession.shared.download(for: request, delegate: capture)
    }

    func download(resumeFrom data: Data, capture: DownloadTaskCapture) async throws -> (URL, URLResponse) {
        try await URLSession.shared.download(resumeFrom: data, delegate: capture)
    }
}

/// Remembers the task the session created for a download. `captured` is read and written only under `lock`.
nonisolated final class DownloadTaskCapture: NSObject, URLSessionTaskDelegate, @unchecked Sendable {

    private let lock = NSLock()
    private var captured: URLSessionTask?

    var task: URLSessionTask? {
        lock.withLock { captured }
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        lock.withLock { captured = task }
    }
}
