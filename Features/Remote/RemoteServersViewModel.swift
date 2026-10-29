import FlaccyCore
import FlaccyEngine
import Foundation

/// The state behind the Servers screens on iPhone and Mac: the servers with their song counts and
/// sync state, the cache's size and limit, and every action a server offers. The screens render
/// `rows` and `cacheCaption` and call the actions; `onChange` tells them to render again.
@MainActor
final class RemoteServersViewModel {

    static let cacheLimitRange = 1...50
    private static let bytesPerGigabyte: Int64 = 1_073_741_824

    var onChange: (() -> Void)?

    private(set) var rows: [RemoteServerRow] = []
    private(set) var cacheCaption = ""
    private var observers: [NSObjectProtocol] = []
    private var usageTask: Task<Void, Never>?

    var cacheLimitGigabytes: Int {
        get {
            let bytes = RemoteStreamCache.capBytes
            return min(Self.cacheLimitRange.upperBound, max(Self.cacheLimitRange.lowerBound, Int((Double(bytes) / Double(Self.bytesPerGigabyte)).rounded())))
        }
        set {
            let clamped = min(Self.cacheLimitRange.upperBound, max(Self.cacheLimitRange.lowerBound, newValue))
            RemoteStreamCache.capBytes = Int64(clamped) * Self.bytesPerGigabyte
            Task { await RemoteStreamCache.shared.evictIfNeeded() }
            refreshCacheUsage()
        }
    }

    func start() {
        let center = NotificationCenter.default
        let names = [
            RemoteServers.didChange, RemoteSyncStatus.didChange, RemoteAvailability.didChange,
            FlaccyServerStatusStore.didChange,
        ]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            })
        }
        reload()
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        usageTask?.cancel()
    }

    func reload() {
        let records = (try? DatabaseManager.shared.fetchRemoteServers()) ?? []
        let counts = (try? DatabaseManager.shared.fetchRemoteSongCounts()) ?? [:]
        rows = records.map { record in
            RemoteServerRow(record: record, songCount: counts[record.id] ?? 0, flaccy: flaccyModel(for: record, songCount: counts[record.id] ?? 0))
        }
        onChange?()
        refreshCacheUsage()
    }

    private func flaccyModel(for record: RemoteServerRecord, songCount: Int) -> FlaccyServerRowModel? {
        let store = FlaccyServerStatusStore.shared
        guard record.isFlaccyServer, store.isConnected, ServerSyncService.engine.connectedServer?.url.absoluteString == record.baseURL
        else { return nil }
        return FlaccyServerRowModel(status: store.status, songCount: songCount, deviceCount: store.deviceCount)
    }

    func refreshCacheUsage() {
        usageTask?.cancel()
        usageTask = Task { [weak self] in
            let usage = await Task.detached(priority: .utility) {
                (RemoteStreamCache.shared.cachedBytes(), RemoteStreamCache.shared.downloadedBytes())
            }.value
            guard !Task.isCancelled, let self else { return }
            let caption = RemoteCopy.cacheUsage(cached: usage.0, downloaded: usage.1)
            guard caption != self.cacheCaption else { return }
            self.cacheCaption = caption
            self.onChange?()
        }
    }

    func refresh(serverID: String) {
        Task { _ = try? await RemoteCatalogSync.shared.sync(serverID: serverID) }
    }

    func refreshAll() {
        for row in rows { refresh(serverID: row.id) }
    }

    func rename(serverID: String, to name: String) async throws {
        try await RemoteServers.shared.update(id: serverID, name: name)
    }

    /// Removes a server with its songs and files and returns the sentence to tell the person.
    func remove(serverID: String) async throws -> String {
        let row = rows.first { $0.id == serverID }
        try await RemoteServers.shared.remove(id: serverID)
        return RemoteCopy.removed(name: row?.name ?? serverID, songCount: row?.songCount ?? 0)
    }

    func test(address: String, authentication: RemoteAuthentication) async -> Result<RemoteServerSummary, RemoteFailure> {
        do {
            return .success(try await RemoteServers.shared.test(address: address, authentication: authentication))
        } catch {
            let host = ServerAddress.normalize(address)?.host ?? address
            return .failure(RemoteFailure.from(error, host: host))
        }
    }

    func add(address: String, name: String?, authentication: RemoteAuthentication) async -> Result<RemoteServerRecord, RemoteFailure> {
        do {
            return .success(try await RemoteServers.shared.add(address: address, name: name, authentication: authentication))
        } catch {
            let host = ServerAddress.normalize(address)?.host ?? address
            return .failure(RemoteFailure.from(error, host: host))
        }
    }

    func clearCache() async -> Int64 {
        let freed = await RemoteStreamCache.shared.clearCache()
        refreshCacheUsage()
        return freed
    }

    /// The name a new server gets until the person types one: its host.
    static func suggestedName(forAddress address: String) -> String {
        ServerAddress.normalize(address)?.host ?? ""
    }
}
