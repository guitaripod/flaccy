import Foundation

/// Fetches over HTTPS only, refuses a redirect to anything else, gives up on a
/// body past the cap while it is still arriving, and treats every status but
/// 200 as a failure. One session serves every request; per-request state is
/// kept by task identifier.
nonisolated final class BoundedHTTPSFetcher: NSObject, URLSessionDataDelegate, @unchecked Sendable {

    enum Failure: Error {
        case insecure
        case badStatus(Int)
        case tooLarge
    }

    private struct Pending {
        var data = Data()
        var failure: Failure?
        let continuation: CheckedContinuation<Data, Error>
    }

    private let maximumBytes: Int
    private let lock = NSLock()
    private var pending = [Int: Pending]()
    private var session: URLSession!

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    func fetch(_ url: URL, headers: [String: String] = [:]) async throws -> Data {
        guard url.scheme?.lowercased() == "https" else { throw Failure.insecure }
        var request = URLRequest(url: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                pending[task.taskIdentifier] = Pending(continuation: continuation)
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status != 200 {
            fail(dataTask, with: .badStatus(status))
            completionHandler(.cancel)
        } else if response.expectedContentLength > Int64(maximumBytes) {
            fail(dataTask, with: .tooLarge)
            completionHandler(.cancel)
        } else {
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        pending[dataTask.taskIdentifier]?.data.append(data)
        let size = pending[dataTask.taskIdentifier]?.data.count ?? 0
        lock.unlock()
        if size > maximumBytes {
            fail(dataTask, with: .tooLarge)
            dataTask.cancel()
        }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        if request.url?.scheme?.lowercased() == "https" {
            completionHandler(request)
        } else {
            fail(task, with: .insecure)
            completionHandler(nil)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let finished = pending.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let finished else { return }
        if let failure = finished.failure {
            finished.continuation.resume(throwing: failure)
        } else if let error {
            finished.continuation.resume(throwing: error)
        } else {
            finished.continuation.resume(returning: finished.data)
        }
    }

    private func fail(_ task: URLSessionTask, with failure: Failure) {
        lock.lock()
        if pending[task.taskIdentifier]?.failure == nil {
            pending[task.taskIdentifier]?.failure = failure
        }
        lock.unlock()
    }
}
