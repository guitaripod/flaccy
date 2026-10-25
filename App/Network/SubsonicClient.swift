import CryptoKit
import FlaccyCore
import Foundation

/// The bytes of a song a request asks for: `start` up to but not including `end`, or to the end of the file.
nonisolated struct RemoteStreamRange: Sendable, Equatable {
    let start: Int64
    let end: Int64?

    var headerValue: String {
        end.map { "bytes=\(start)-\($0 - 1)" } ?? "bytes=\(start)-"
    }
}

/// What a stream response says about the file behind it, read off its headers.
nonisolated struct RemoteStreamHead: Sendable, Equatable {
    let statusCode: Int
    let contentLength: Int64?
    let rangeStart: Int64?
    let totalBytes: Int64?
    let validator: String?

    init(statusCode: Int, contentLength: Int64?, rangeStart: Int64?, totalBytes: Int64?, validator: String?) {
        self.statusCode = statusCode
        self.contentLength = contentLength
        self.rangeStart = rangeStart
        self.totalBytes = totalBytes
        self.validator = validator
    }

    /// Reads `Content-Range`, `Content-Length` and the validator (a strong `ETag`, else `Last-Modified`).
    init(response: HTTPURLResponse) {
        let length = response.value(forHTTPHeaderField: "Content-Length").flatMap { Int64($0) }
        var rangeStart: Int64?
        var total: Int64?
        if let contentRange = response.value(forHTTPHeaderField: "Content-Range") {
            (rangeStart, total) = Self.parse(contentRange: contentRange)
        } else if response.statusCode == 200 {
            rangeStart = 0
            total = length
        }
        let etag = response.value(forHTTPHeaderField: "ETag").flatMap { $0.hasPrefix("W/") ? nil : $0 }
        self.init(
            statusCode: response.statusCode,
            contentLength: length,
            rangeStart: rangeStart,
            totalBytes: total,
            validator: etag ?? response.value(forHTTPHeaderField: "Last-Modified")
        )
    }

    /// `bytes 0-99/313276` gives a start of 0 and a total of 313276; a `*` total is unknown.
    static func parse(contentRange: String) -> (start: Int64?, total: Int64?) {
        let parts = contentRange.split(separator: " ", maxSplits: 1)
        guard parts.count == 2 else { return (nil, nil) }
        let spans = parts[1].split(separator: "/", maxSplits: 1)
        guard spans.count == 2 else { return (nil, nil) }
        let start = spans[0].split(separator: "-").first.flatMap { Int64($0) }
        return (start, Int64(spans[1]))
    }
}

/// An open stream response: its head, the body as it arrives, and a way to stop it.
nonisolated struct RemoteByteStream: Sendable {
    let head: RemoteStreamHead
    let chunks: AsyncThrowingStream<Data, Error>
    let cancel: @Sendable () -> Void
}

/// One Subsonic or OpenSubsonic server: builds each signed URL, makes the call, and maps what
/// goes wrong to a `RemoteFailure` that names the host. The secret never leaves this actor in
/// a log line or an error; the URLs it builds carry it, so they are never logged.
actor SubsonicClient {

    nonisolated let serverID: String
    nonisolated let host: String
    private let base: URL
    private let credentials: SubsonicCredentials
    private let session: URLSession
    private let streams = SubsonicStreamSession()

    private static let requestTimeout: TimeInterval = 30
    private static let songPageParameters: [(String, String)] = [
        ("query", ""), ("artistCount", "0"), ("albumCount", "0"),
    ]

    init(serverID: String, base: URL, credentials: SubsonicCredentials) {
        self.serverID = serverID
        self.base = base
        self.credentials = credentials
        host = base.host ?? base.absoluteString
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.requestTimeout
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    deinit {
        session.invalidateAndCancel()
    }

    func ping() async throws -> SubsonicResponse.Envelope {
        try await call("ping", [])
    }

    /// The names of the OpenSubsonic extensions the server lists; none for a plain Subsonic server.
    func extensions() async throws -> [String] {
        do {
            let envelope = try await call("getOpenSubsonicExtensions", [])
            return (envelope.openSubsonicExtensions ?? []).map(\.name)
        } catch RemoteFailure.server, RemoteFailure.httpStatus, RemoteFailure.notSubsonic {
            return []
        }
    }

    func songsPage(offset: Int, size: Int) async throws -> [SubsonicResponse.Child] {
        let parameters = Self.songPageParameters + [("songCount", String(size)), ("songOffset", String(offset))]
        return try await call("search3", parameters).searchResult3?.song ?? []
    }

    func albumsPage(offset: Int, size: Int) async throws -> [SubsonicResponse.AlbumID3] {
        let parameters = [("type", "alphabeticalByName"), ("size", String(size)), ("offset", String(offset))]
        return try await call("getAlbumList2", parameters).albumList2?.album ?? []
    }

    /// The number of songs the server holds, summed from its albums' song counts; nil when it cannot say.
    func songTotal() async -> Int? {
        var total = 0
        var offset = 0
        var previousFirst: String?
        while true {
            guard let page = try? await albumsPage(offset: offset, size: 500) else { return nil }
            guard let first = page.first, first.id != previousFirst else { break }
            previousFirst = first.id
            total += page.reduce(0) { $0 + ($1.songCount ?? 0) }
            offset += page.count
        }
        return total > 0 ? total : nil
    }

    func album(id: String) async throws -> SubsonicResponse.AlbumWithSongs {
        guard let album = try await call("getAlbum", [("id", id)]).album else { throw RemoteFailure.notSubsonic(host: host) }
        return album
    }

    func song(id: String) async throws -> SubsonicResponse.Child {
        guard let song = try await call("getSong", [("id", id)]).song else { throw RemoteFailure.notSubsonic(host: host) }
        return song
    }

    func playlists() async throws -> [SubsonicResponse.Playlist] {
        try await call("getPlaylists", []).playlists?.playlist ?? []
    }

    func playlist(id: String) async throws -> SubsonicResponse.PlaylistWithEntries {
        guard let playlist = try await call("getPlaylist", [("id", id)]).playlist else { throw RemoteFailure.notSubsonic(host: host) }
        return playlist
    }

    /// Tells the server a song started (`submission: false`) or was listened to (`submission: true`).
    func scrobble(id: String, at date: Date, submission: Bool) async throws {
        let milliseconds = Int64((date.timeIntervalSince1970 * 1000).rounded())
        _ = try await call("scrobble", [
            ("id", id), ("time", String(milliseconds)), ("submission", submission ? "true" : "false"),
        ])
    }

    func star(id: String) async throws {
        _ = try await call("star", [("id", id)])
    }

    func unstar(id: String) async throws {
        _ = try await call("unstar", [("id", id)])
    }

    nonisolated func coverArtURL(id: String, size: Int) -> URL {
        signedURL("getCoverArt", [("id", id), ("size", String(size))])
    }

    /// The image bytes of a cover, or nil when the server has none under that id.
    func coverArt(id: String, size: Int) async throws -> Data? {
        var request = URLRequest(url: coverArtURL(id: id, size: size))
        request.timeoutInterval = Self.requestTimeout
        let (data, response) = try await perform(request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              response.mimeType?.hasPrefix("image/") == true
        else { return nil }
        return data
    }

    /// The request for a song's original bytes: `format=raw`, with `Range` for the part wanted
    /// and `If-Range` so a file that changed in between is sent whole instead of spliced.
    nonisolated func streamRequest(id: String, range: RemoteStreamRange, validator: String?) -> URLRequest {
        var request = URLRequest(url: signedURL("stream", [("id", id), ("format", "raw")]))
        request.setValue(range.headerValue, forHTTPHeaderField: "Range")
        if let validator { request.setValue(validator, forHTTPHeaderField: "If-Range") }
        return request
    }

    /// Opens a stream and waits for its head. The body follows through `chunks` as it arrives.
    func openStream(id: String, range: RemoteStreamRange, validator: String?) async throws -> RemoteByteStream {
        let request = streamRequest(id: id, range: range, validator: validator)
        do {
            let (response, chunks, cancel) = try await streams.open(request)
            return RemoteByteStream(head: RemoteStreamHead(response: response), chunks: chunks, cancel: cancel)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw RemoteFailure.from(error, host: host)
        }
    }

    /// Downloads a song through the server's `download` call into a temporary file, for checking a cached copy byte for byte.
    func download(id: String) async throws -> URL {
        var request = URLRequest(url: signedURL("download", [("id", id)]))
        request.timeoutInterval = Self.requestTimeout
        do {
            let (location, response) = try await session.download(for: request)
            guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
                throw RemoteFailure.httpStatus((response as? HTTPURLResponse)?.statusCode ?? 0, host: host)
            }
            return location
        } catch let error as URLError {
            throw RemoteFailure(transport: error, host: host)
        }
    }

    private func call(_ method: String, _ parameters: [(String, String)]) async throws -> SubsonicResponse.Envelope {
        var request = URLRequest(url: signedURL(method, parameters))
        request.timeoutInterval = Self.requestTimeout
        let (data, response) = try await perform(request)
        let envelope: SubsonicResponse.Envelope
        do {
            envelope = try SubsonicResponse.decode(data)
        } catch {
            if let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
                throw RemoteFailure.httpStatus(status, host: host)
            }
            throw RemoteFailure.notSubsonic(host: host)
        }
        if let failure = envelope.failure {
            throw RemoteFailure(subsonic: failure, code: envelope.error?.code, message: envelope.error?.message, host: host)
        }
        return envelope
    }

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            throw RemoteFailure(transport: error, host: host)
        }
    }

    nonisolated private func signedURL(_ method: String, _ parameters: [(String, String)]) -> URL {
        SubsonicRequest.url(
            base: base,
            method: method,
            parameters: parameters,
            credentials: credentials,
            salt: Self.makeSalt(),
            md5Hex: Self.md5Hex
        )
    }

    nonisolated private static func makeSalt() -> String {
        String(format: "%016llx", UInt64.random(in: UInt64.min...UInt64.max))
    }

    nonisolated private static func md5Hex(_ text: String) -> String {
        Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// A URL session that hands a response's head back first and its body chunk by chunk as it
/// arrives, which a file being cached for playback needs and a `data(for:)` call cannot give.
nonisolated final class SubsonicStreamSession: NSObject, URLSessionDataDelegate, @unchecked Sendable {

    private struct Pending {
        var head: CheckedContinuation<HTTPURLResponse, Error>?
        let chunks: AsyncThrowingStream<Data, Error>.Continuation
    }

    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]
    private var session: URLSession!

    override init() {
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 600
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    deinit {
        session.invalidateAndCancel()
    }

    func open(_ request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>, @Sendable () -> Void) {
        let task = session.dataTask(with: request)
        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        let chunks = AsyncThrowingStream<Data, Error>(bufferingPolicy: .unbounded) { continuation = $0 }
        let chunkContinuation = continuation!
        chunkContinuation.onTermination = { _ in task.cancel() }
        let response: HTTPURLResponse = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { head in
                lock.withLock { pending[task.taskIdentifier] = Pending(head: head, chunks: chunkContinuation) }
                if Task.isCancelled {
                    task.cancel()
                } else {
                    task.resume()
                }
            }
        } onCancel: {
            task.cancel()
        }
        return (response, chunks, { task.cancel() })
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        let head = lock.withLock { () -> CheckedContinuation<HTTPURLResponse, Error>? in
            let continuation = pending[dataTask.taskIdentifier]?.head
            pending[dataTask.taskIdentifier]?.head = nil
            return continuation
        }
        if let http = response as? HTTPURLResponse {
            head?.resume(returning: http)
            completionHandler(.allow)
        } else {
            head?.resume(throwing: URLError(.badServerResponse))
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let chunks = lock.withLock { pending[dataTask.taskIdentifier]?.chunks }
        chunks?.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let entry = lock.withLock { pending.removeValue(forKey: task.taskIdentifier) }
        guard let entry else { return }
        if let error {
            entry.head?.resume(throwing: error)
            entry.chunks.finish(throwing: error)
        } else {
            entry.chunks.finish()
        }
    }
}
