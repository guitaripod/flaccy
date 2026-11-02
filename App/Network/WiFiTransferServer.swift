import FlaccyCore
import Foundation
import MidgarCore
import Network

/// Why a file the browser sent was not kept.
nonisolated enum WiFiTransferDropReason: Sendable, Equatable {
    case refused(WiFiTransferRefusal)
    case noSpace
    case interrupted
}

/// What the transfer screen hears from the server, on the main actor.
nonisolated enum WiFiTransferEvent: Sendable, Equatable {
    /// Listening on `port`.
    case listening(port: UInt16)
    /// The listener could not start, or stopped working.
    case failed
    /// A file is arriving.
    case receiving(fileName: String, received: Int64, expected: Int64)
    /// A file arrived whole and waits in its batch's folder.
    case received(fileName: String)
    /// A file was turned away or broke off; nothing of it was kept.
    case dropped(fileName: String?, reason: WiFiTransferDropReason)
    /// The page sent everything in a batch, which now waits in `folder` to be imported.
    case batchFinished(folder: URL)
}

/// Wi-Fi Transfer's web server. While its screen is open, a browser on the same network loads the upload page from it
/// and sends songs one request each. Each song is written to a hidden `.part` file that takes its real name only once
/// the last byte is in, inside a staging folder per drop, which the screen imports when the page says the drop is done.
///
/// It listens on 8080, or on any free port when 8080 is taken, and serves only peers on the local network or the
/// person's Tailscale network (`WiFiTransferProtocol.isNearby`), checked on each connection rather than with
/// `acceptLocalOnly`, whose NECP enforcement drops every connection under the simulator. Listening and accepting need
/// no Local Network permission (TN3179), and nothing is advertised over Bonjour, so opening the screen shows no system
/// alert. The routes and their token are `WiFiTransferProtocol`'s.
///
/// The listener's state and every connection's are touched only on `queue`, which is why it is `@unchecked Sendable`.
nonisolated final class WiFiTransferServer: @unchecked Sendable {

    static let preferredPort: NWEndpoint.Port = 8080
    /// Room left free on the device beyond what a drop will need once it is imported.
    static let spaceReserve: Int64 = 256 * 1024 * 1024
    private static let readChunk = 1024 * 1024
    private static let progressInterval: TimeInterval = 0.25

    let token: String
    let stagingRoot: URL

    private let page: Data
    private let acceptedExtensions: Set<String>
    private let freeSpace: @Sendable (URL) -> Int64?
    private let onEvent: @MainActor @Sendable (WiFiTransferEvent) -> Void
    private let queue = DispatchQueue(label: "cc.midgarcorp.flaccy.wifi-transfer")
    private var listener: NWListener?
    private var exchanges: [ObjectIdentifier: Exchange] = [:]
    private var stagedBytes: [String: Int64] = [:]
    private var isStopped = false

    /// One connection's request: the head as it arrives, then the upload it is writing, if any. Touched only on the
    /// server's queue, like the rest of its state.
    private nonisolated final class Exchange: @unchecked Sendable {
        let connection: NWConnection
        var buffer = Data()
        var upload: Upload?

        init(connection: NWConnection) {
            self.connection = connection
        }
    }

    private nonisolated struct Upload {
        let request: WiFiTransferUpload
        let handle: FileHandle
        let partURL: URL
        let finalURL: URL
        var received: Int64 = 0
        var lastProgress = Date.distantPast
    }

    /// - Parameters:
    ///   - page: The upload page, served as is.
    ///   - acceptedExtensions: Lowercased extensions of the files Flaccy imports; anything else is refused.
    ///   - freeSpace: The bytes the device will still give at a URL, nil when it will not say.
    init(
        token: String,
        stagingRoot: URL,
        page: Data,
        acceptedExtensions: Set<String>,
        freeSpace: @escaping @Sendable (URL) -> Int64? = WiFiTransferServer.availableCapacity,
        onEvent: @escaping @MainActor @Sendable (WiFiTransferEvent) -> Void
    ) {
        self.token = token
        self.stagingRoot = stagingRoot
        self.page = page
        self.acceptedExtensions = acceptedExtensions
        self.freeSpace = freeSpace
        self.onEvent = onEvent
    }

    func start() {
        queue.async { [self] in
            guard listener == nil, !isStopped else { return }
            listen(on: Self.preferredPort)
        }
    }

    /// Starts listening again after the system tore the listener down, as it may while the app was in the background.
    func restartIfNeeded() {
        queue.async { [self] in
            guard listener == nil, !isStopped else { return }
            listen(on: Self.preferredPort)
        }
    }

    /// Stops listening, drops every connection and deletes the part of any song still arriving. Finished songs stay.
    func stop() {
        queue.async { [self] in
            isStopped = true
            listener?.cancel()
            listener = nil
            for exchange in exchanges.values {
                abandon(exchange)
                exchange.connection.cancel()
            }
            exchanges.removeAll()
        }
    }

    /// The bytes the volume holding `url` will still give to something the person asked for.
    static func availableCapacity(at url: URL) -> Int64? {
        let probe = FileManager.default.fileExists(atPath: url.path) ? url : url.deletingLastPathComponent()
        return (try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    private func listen(on port: NWEndpoint.Port) {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let created: NWListener
        do {
            created = try NWListener(using: parameters, on: port)
        } catch {
            MidgarLog.error("Wi-Fi Transfer could not listen on \(port): \(error)", category: .network)
            if port == Self.preferredPort { listen(on: .any) } else { emit(.failed) }
            return
        }
        listener = created
        created.stateUpdateHandler = { [weak self] state in
            self?.listenerChanged(created, to: state, port: port)
        }
        created.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        created.start(queue: queue)
    }

    private func listenerChanged(_ listener: NWListener, to state: NWListener.State, port: NWEndpoint.Port) {
        guard listener === self.listener else { return }
        switch state {
        case .ready:
            let bound = listener.port?.rawValue ?? port.rawValue
            MidgarLog.info("Wi-Fi Transfer listening on \(bound)", category: .network)
            emit(.listening(port: bound))
        case .failed(let error):
            MidgarLog.error("Wi-Fi Transfer listener failed on \(port): \(error)", category: .network)
            listener.cancel()
            self.listener = nil
            if port == Self.preferredPort, case .posix(.EADDRINUSE) = error {
                listen(on: .any)
            } else {
                emit(.failed)
            }
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        guard !isStopped, Self.isNearby(connection.endpoint) else {
            if !isStopped { MidgarLog.info("Wi-Fi Transfer refused a connection from outside the local network", category: .network) }
            connection.cancel()
            return
        }
        let exchange = Exchange(connection: connection)
        let id = ObjectIdentifier(connection)
        exchanges[id] = exchange
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.close(id)
            default:
                break
            }
        }
        connection.start(queue: queue)
        readHead(exchange)
    }

    private static func isNearby(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address): return WiFiTransferProtocol.isNearby(host: "\(address)")
        case .ipv6(let address): return WiFiTransferProtocol.isNearby(host: "\(address)")
        case .name: return false
        @unknown default: return false
        }
    }

    private func close(_ id: ObjectIdentifier) {
        guard let exchange = exchanges.removeValue(forKey: id) else { return }
        if exchange.upload != nil {
            abandon(exchange)
            emit(.dropped(fileName: nil, reason: .interrupted))
        }
    }

    private func readHead(_ exchange: Exchange) {
        exchange.connection.receive(minimumIncompleteLength: 1, maximumLength: Self.readChunk) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { exchange.buffer.append(data) }
            switch WiFiTransferRequestHead.parse(exchange.buffer) {
            case .incomplete:
                if isComplete || error != nil {
                    exchange.connection.cancel()
                } else {
                    readHead(exchange)
                }
            case .malformed:
                respond(exchange, WiFiTransferResponse.json(status: 400, error: "request"))
            case .complete(let head, let bodyOffset):
                let body = exchange.buffer.dropFirst(bodyOffset)
                exchange.buffer = Data()
                handle(head, body: Data(body), on: exchange)
            }
        }
    }

    private func handle(_ head: WiFiTransferRequestHead, body: Data, on exchange: Exchange) {
        switch WiFiTransferRoute.route(head, token: token, acceptedExtensions: acceptedExtensions) {
        case .page:
            respond(exchange, WiFiTransferResponse.make(
                status: 200, contentType: "text/html; charset=utf-8", body: page, includeBody: head.method != "HEAD"
            ))
        case .notFound:
            respond(exchange, WiFiTransferResponse.json(status: 404, error: "not-found"))
        case .refuse(let refusal):
            let name = head.query["path"].flatMap { $0.split(separator: "/").last.map(String.init) }
            emit(.dropped(fileName: name, reason: .refused(refusal)))
            respond(exchange, WiFiTransferResponse.json(status: refusal.status, error: "\(refusal)"))
        case .finish(let batch):
            finish(batch: batch, on: exchange)
        case .upload(let request):
            begin(request, body: body, on: exchange)
        }
    }

    private func finish(batch: String, on exchange: Exchange) {
        let folder = stagingRoot.appendingPathComponent(batch, isDirectory: true)
        stagedBytes[batch] = nil
        if FileManager.default.fileExists(atPath: folder.path) {
            emit(.batchFinished(folder: folder))
        }
        respond(exchange, WiFiTransferResponse.json(status: 200))
    }

    private func begin(_ request: WiFiTransferUpload, body: Data, on exchange: Exchange) {
        let staged = stagedBytes[request.batch, default: 0]
        guard hasRoom(for: request.length, alongside: staged) else {
            emit(.dropped(fileName: request.fileName, reason: .noSpace))
            respond(exchange, WiFiTransferResponse.json(status: 507, error: "space"))
            return
        }
        let finalURL = stagingRoot
            .appendingPathComponent(request.batch, isDirectory: true)
            .appendingPathComponent(request.relativePath)
        let partURL = finalURL.deletingLastPathComponent().appendingPathComponent(".\(finalURL.lastPathComponent).part")
        let handle: FileHandle
        do {
            try FileManager.default.createDirectory(at: partURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: partURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            handle = try FileHandle(forWritingTo: partURL)
        } catch {
            MidgarLog.error("Wi-Fi Transfer could not stage \(request.fileName): \(error)", category: .network)
            emit(.dropped(fileName: request.fileName, reason: .interrupted))
            respond(exchange, WiFiTransferResponse.json(status: 503, error: "write"))
            return
        }
        exchange.upload = Upload(request: request, handle: handle, partURL: partURL, finalURL: finalURL)
        emit(.receiving(fileName: request.fileName, received: 0, expected: request.length))
        guard write(body, on: exchange) else { return }
        continueUpload(exchange)
    }

    /// Room for the song now, and for the whole drop again when the import copies it into the library.
    private func hasRoom(for length: Int64, alongside staged: Int64) -> Bool {
        guard let free = freeSpace(stagingRoot) else { return true }
        return free >= staged + 2 * length + Self.spaceReserve
    }

    private func continueUpload(_ exchange: Exchange) {
        guard let upload = exchange.upload else { return }
        if upload.received >= upload.request.length {
            complete(exchange)
            return
        }
        exchange.connection.receive(minimumIncompleteLength: 1, maximumLength: Self.readChunk) { [weak self] data, _, isComplete, error in
            guard let self, exchange.upload != nil else { return }
            if let data, !data.isEmpty {
                guard write(data, on: exchange) else { return }
            }
            if let upload = exchange.upload, upload.received >= upload.request.length {
                complete(exchange)
            } else if isComplete || error != nil {
                let name = exchange.upload?.request.fileName
                abandon(exchange)
                emit(.dropped(fileName: name, reason: .interrupted))
                exchange.connection.cancel()
            } else {
                continueUpload(exchange)
            }
        }
    }

    /// Appends at most the bytes the upload still expects. False when the write failed and the upload was dropped.
    private func write(_ data: Data, on exchange: Exchange) -> Bool {
        guard var upload = exchange.upload, !data.isEmpty else { return true }
        let remaining = upload.request.length - upload.received
        let slice = data.count > remaining ? data.prefix(Int(remaining)) : data
        do {
            try upload.handle.write(contentsOf: slice)
        } catch {
            MidgarLog.error("Wi-Fi Transfer write failed for \(upload.request.fileName): \(error)", category: .network)
            abandon(exchange)
            emit(.dropped(fileName: upload.request.fileName, reason: .noSpace))
            respond(exchange, WiFiTransferResponse.json(status: 507, error: "space"))
            return false
        }
        upload.received += Int64(slice.count)
        let now = Date()
        if now.timeIntervalSince(upload.lastProgress) >= Self.progressInterval {
            upload.lastProgress = now
            emit(.receiving(fileName: upload.request.fileName, received: upload.received, expected: upload.request.length))
        }
        exchange.upload = upload
        return true
    }

    private func complete(_ exchange: Exchange) {
        guard let upload = exchange.upload else { return }
        exchange.upload = nil
        do {
            try upload.handle.close()
            if FileManager.default.fileExists(atPath: upload.finalURL.path) {
                try FileManager.default.removeItem(at: upload.finalURL)
            }
            try FileManager.default.moveItem(at: upload.partURL, to: upload.finalURL)
        } catch {
            MidgarLog.error("Wi-Fi Transfer could not keep \(upload.request.fileName): \(error)", category: .network)
            try? FileManager.default.removeItem(at: upload.partURL)
            emit(.dropped(fileName: upload.request.fileName, reason: .interrupted))
            respond(exchange, WiFiTransferResponse.json(status: 503, error: "write"))
            return
        }
        stagedBytes[upload.request.batch, default: 0] += upload.request.length
        emit(.received(fileName: upload.request.fileName))
        respond(exchange, WiFiTransferResponse.json(status: 201))
    }

    /// Closes and deletes the part of a song that will not finish.
    private func abandon(_ exchange: Exchange) {
        guard let upload = exchange.upload else { return }
        exchange.upload = nil
        try? upload.handle.close()
        try? FileManager.default.removeItem(at: upload.partURL)
    }

    /// Sends the whole response, then closes; the page opens a new connection for the next request.
    private func respond(_ exchange: Exchange, _ response: Data) {
        let connection = exchange.connection
        connection.send(content: response, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    /// Delivers in the order the events happened, which a `Task` per event would not promise.
    private func emit(_ event: WiFiTransferEvent) {
        let onEvent = onEvent
        DispatchQueue.main.async {
            MainActor.assumeIsolated { onEvent(event) }
        }
    }
}
