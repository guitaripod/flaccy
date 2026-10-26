import FlaccyCore
import Foundation

extension ServerSyncEngine {

    /// Enrolls this device with the server a link names and queues what the library already holds for it. Unless
    /// `startSyncing` is false, the first round of syncing starts in the background; watch `statusUpdates()` for it.
    @discardableResult
    public func connect(
        link: FlaccyServerLink, deviceName: String, startSyncing: Bool = true
    ) async throws -> ServerSyncConnection {
        let anonymous = configuration.transports.transport(baseURL: link.baseURL, token: nil)
        let hello = try await retrying { try await anonymous.hello() }
        try Self.checkCompatible(hello)
        let instance = ServerSyncIDs.uuidV7(nowMs: configuration.nowMs())
        let request = ServerEnrollRequest(
            enroll: link.enrollmentCode, name: deviceName, platform: configuration.platform, instance: instance
        )
        let reply = try await retrying { try await anonymous.enroll(request) }
        let serverID = serverID(for: link.baseURL.absoluteString)
        if let previous = currentLink() {
            configuration.tokens.removeToken(serverID: self.serverID(for: previous.serverURL))
        }
        do {
            try configuration.tokens.setToken(reply.token, serverID: serverID)
        } catch {
            logError("The device token could not be stored in the Keychain")
            throw ServerSyncError.malformed("the device token could not be stored")
        }
        let report: ServerSyncImportReport
        do {
            report = try store.attach(ServerSyncEnrollment(
                serverURL: link.baseURL.absoluteString, serverName: link.name ?? hello.server.name,
                device: reply.device, user: reply.user.id, incarnation: reply.incarnation, instance: instance,
                serverTimeMs: reply.serverTimeMs
            ))
        } catch {
            configuration.tokens.removeToken(serverID: serverID)
            logError("Attaching to the server failed: \(error.localizedDescription)")
            throw ServerSyncError.malformed("the library could not be prepared for sync")
        }
        log("Connected to \(hello.server.name); queued \(report.playlists) playlists, \(report.entries) songs, \(report.loves) loves")
        installLocalChangeHandler()
        publish(.syncing(changes: (try? store.unsentCount()) ?? 0))
        if startSyncing { Task { await self.syncNow() } }
        return ServerSyncConnection(
            serverName: link.name ?? hello.server.name, deviceID: reply.device, userID: reply.user.id, imported: report
        )
    }

    static func checkCompatible(_ hello: ServerHello) throws {
        guard hello.protocols.contains(1) else {
            throw (hello.protocols.max() ?? 0) > 1 ? ServerSyncError.appTooOld : ServerSyncError.serverTooOld
        }
        guard hello.features.contains("sync") else { throw ServerSyncError.serverTooOld }
    }

    /// Forgets the server: the token, the base and the queue. Playlists, loves and plays stay as they are, and the server keeps its copy.
    public func disconnect() async throws {
        debounceTask?.cancel()
        periodicTask?.cancel()
        roundTask?.cancel()
        if let link = currentLink() {
            configuration.tokens.removeToken(serverID: serverID(for: link.serverURL))
        }
        try store.detach()
        lastFailure = nil
        publish(.notConnected)
    }

    /// The devices of the signed-in person, this one marked `current`.
    public func devices() async throws -> [ServerDevice] {
        let transport = try authenticatedTransport()
        return try await retrying { try await transport.devices() }
    }

    public func renameDevice(id: String, name: String) async throws {
        let transport = try authenticatedTransport()
        try await retrying { try await transport.renameDevice(id: id, name: name) }
    }

    /// Revokes another device; it stops syncing on its next request.
    public func removeDevice(id: String) async throws {
        let transport = try authenticatedTransport()
        try await retrying { try await transport.revokeDevice(id: id) }
    }

    private func authenticatedTransport() throws -> any ServerSyncTransport {
        guard let link = currentLink() else { throw ServerSyncError.notConnected }
        return try makeTransport(link: link)
    }

    /// Pauses or resumes syncing with the server ("Sync with arch"). Local writes keep queueing while paused.
    public func setPaused(_ paused: Bool) {
        try? store.setMeta(SyncMeta.paused, paused ? "1" : nil)
        if paused {
            publish(.paused)
        } else {
            Task { await self.syncNow() }
        }
    }

    /// How many local changes still wait for the server, refused ones included until a complete pull drops them.
    public func pendingChangeCount() -> Int {
        (try? store.pendingCount()) ?? 0
    }

    public var isPaused: Bool {
        ((try? store.meta(SyncMeta.paused)) ?? nil) != nil
    }
}
