import FlaccyCore
import Foundation
import MidgarCore

/// What the engine needs from the app around it.
public struct ServerSyncConfiguration: Sendable {
    public var transports: any ServerSyncTransportFactory
    public var tokens: any ServerTokenStore
    public var scalarSink: (any ServerScalarSink)?
    public var backoff: ServerSyncBackoff
    public var platform: String
    public var isEntitled: @Sendable () -> Bool
    public var sleep: @Sendable (Double) async -> Void
    public var jitter: @Sendable () -> Double
    public var localChangeDelaySeconds: Double?
    public var periodSeconds: Double
    public var nowMs: @Sendable () -> Int64

    public init(
        transports: any ServerSyncTransportFactory,
        tokens: any ServerTokenStore,
        scalarSink: (any ServerScalarSink)? = nil,
        backoff: ServerSyncBackoff = .standard,
        platform: String,
        isEntitled: @escaping @Sendable () -> Bool = { true },
        sleep: @escaping @Sendable (Double) async -> Void = { seconds in
            try? await Task.sleep(for: .seconds(seconds))
        },
        jitter: @escaping @Sendable () -> Double = { Double.random(in: 0...1) },
        localChangeDelaySeconds: Double? = 2,
        periodSeconds: Double = 300,
        nowMs: @escaping @Sendable () -> Int64 = ServerSyncGate.systemClock
    ) {
        self.transports = transports
        self.tokens = tokens
        self.scalarSink = scalarSink
        self.backoff = backoff
        self.platform = platform
        self.isEntitled = isEntitled
        self.sleep = sleep
        self.jitter = jitter
        self.localChangeDelaySeconds = localChangeDelaySeconds
        self.periodSeconds = periodSeconds
        self.nowMs = nowMs
    }
}

/// What connecting to a server produced.
public struct ServerSyncConnection: Sendable, Equatable {
    public var serverName: String
    public var deviceID: String
    public var userID: String
    public var imported: ServerSyncImportReport
}

/// Syncs the library database with one Flaccy Server: the playlists, loves, lyric offsets, settings and play history of the person.
///
/// Every local write is recorded as a mutation in the transaction that makes it. The engine pushes the queue, pulls the server's
/// changes, and materializes them into the app tables, following the reference client of `linux/server-core/src/sim/client.rs`:
/// a mutation leaves the queue only when a complete pull confirms it, and a replaced server is rebuilt from the base.
public actor ServerSyncEngine {

    static let maxRestarts = 4
    static let maxPushRounds = 200

    let store: ServerSyncStore
    let configuration: ServerSyncConfiguration
    var currentStatus: SyncStatus = .notConnected
    var statusContinuations: [UUID: AsyncStream<SyncStatus>.Continuation] = [:]
    var changeHandler: (@Sendable (ServerSyncChanges) -> Void)?
    var roundTask: Task<Void, Never>?
    var rerunRequested = false
    var debounceTask: Task<Void, Never>?
    var periodicTask: Task<Void, Never>?
    var networkOnline = true
    var lastFailure: ServerSyncError?
    var clockBehind = false

    public init(database: DatabaseManager, configuration: ServerSyncConfiguration) {
        self.store = ServerSyncStore(database: database)
        self.configuration = configuration
        self.currentStatus = store.isConfigured() ? .upToDate(lastSyncedAt: nil) : .notConnected
    }

    /// Where syncing stands now.
    public var status: SyncStatus { currentStatus }

    /// The status, now and at every change after.
    public func statusUpdates() -> AsyncStream<SyncStatus> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<SyncStatus>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.yield(currentStatus)
        statusContinuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        return stream
    }

    /// Hands the screens what changed in the app tables after each pull and push.
    public func setChangeHandler(_ handler: (@Sendable (ServerSyncChanges) -> Void)?) {
        changeHandler = handler
    }

    public var isConnected: Bool { store.isConfigured() }

    public var serverName: String? {
        currentLink()?.serverName
    }

    func currentLink() -> ServerSyncLink? {
        (try? store.link()) ?? nil
    }

    private func removeContinuation(_ id: UUID) {
        statusContinuations[id] = nil
    }

    func publish(_ status: SyncStatus) {
        guard status != currentStatus else { return }
        currentStatus = status
        for continuation in statusContinuations.values { continuation.yield(status) }
    }

    func serverLabel() -> String {
        let name = currentLink()?.serverName ?? ""
        return name.isEmpty ? "your server" : name
    }

    func serverID(for urlText: String) -> String {
        guard let url = URL(string: urlText), let host = url.host else { return urlText.lowercased() }
        return "\(host.lowercased()):\(url.port ?? 0)"
    }

    func makeTransport(link: ServerSyncLink) throws -> any ServerSyncTransport {
        guard let url = URL(string: link.serverURL) else { throw ServerSyncError.notConnected }
        guard let token = configuration.tokens.token(serverID: serverID(for: link.serverURL)) else {
            throw ServerSyncError.unauthorized
        }
        return configuration.transports.transport(baseURL: url, token: token)
    }

    func retrying<T: Sendable>(_ call: () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                return try await call()
            } catch let error as ServerSyncError where error.isTransient && attempt + 1 < configuration.backoff.attempts {
                var pause = configuration.backoff.pause(attempt: attempt, jitter: configuration.jitter())
                if case .rateLimited(let seconds?) = error { pause = min(Double(seconds), 30) }
                await configuration.sleep(pause)
                attempt += 1
            }
        }
    }

    func log(_ message: String) {
        MidgarLog.info(message, category: .sync)
    }

    func logError(_ message: String) {
        MidgarLog.error(message, category: .sync)
    }
}
