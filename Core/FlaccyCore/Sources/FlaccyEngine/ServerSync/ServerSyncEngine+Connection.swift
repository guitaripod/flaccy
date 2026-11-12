import FlaccyCore
import Foundation

extension ServerSyncEngine {

    /// Enrolls this device with the server a link names and queues what the library already holds for it. Unless
    /// `startSyncing` is false, the first round of syncing starts in the background; watch `statusUpdates()` for it.
    @discardableResult
    public func connect(
        link: FlaccyServerLink, deviceName: String, startSyncing: Bool = true
    ) async throws -> ServerSyncConnection {
        let (baseURL, anonymous, hello) = try await reach(link)
        try Self.checkCompatible(hello)
        let instance = ServerSyncIDs.uuidV7(nowMs: configuration.nowMs())
        let request = ServerEnrollRequest(
            enroll: link.enrollmentCode, name: deviceName, platform: configuration.platform, instance: instance
        )
        let reply = try await retrying { try await anonymous.enroll(request) }
        let pin = link.pin ?? anonymous.seenPin
        let serverID = serverID(for: baseURL.absoluteString)
        if let previous = currentLink() {
            configuration.tokens.removeToken(serverID: self.serverID(for: previous.serverURL))
        }
        do {
            try configuration.tokens.setToken(reply.token, serverID: serverID)
        } catch {
            logError("The device token could not be stored in the Keychain")
            throw ServerSyncError.malformed("the device token could not be stored")
        }
        let role = await roleOfNewDevice(baseURL: baseURL, pin: pin, token: reply.token, fallback: reply.user.role)
        var report: ServerSyncImportReport
        do {
            try store.refreshSongKeyIndex()
            report = try store.attach(ServerSyncEnrollment(
                serverURL: baseURL.absoluteString, serverName: link.name ?? hello.server.name, serverPin: pin,
                device: reply.device, user: reply.user.id, incarnation: reply.incarnation, instance: instance,
                serverTimeMs: reply.serverTimeMs
            ), role: role)
        } catch {
            configuration.tokens.removeToken(serverID: serverID)
            logError("Attaching to the server failed: \(error.localizedDescription)")
            throw ServerSyncError.malformed("the library could not be prepared for sync")
        }
        mergeProbe = try? store.mergeProbe()
        connectedBox.set(currentLink().flatMap(ServerSyncServer.init(link:)))
        log("Connected to \(hello.server.name); queued \(report.playlists) playlists, \(report.entries) songs, \(report.loves) loves")
        installLocalChangeHandler()
        let name = link.name ?? hello.server.name
        if let status = SyncStatus.readOnly(role: role, server: name) {
            publish(status)
            return ServerSyncConnection(
                serverName: name, baseURL: baseURL, pin: pin, deviceID: reply.device, userID: reply.user.id, role: role, imported: report
            )
        }
        report = try await importStructure(starting: report)
        publish(.syncing(changes: (try? store.unsentCount()) ?? 0))
        if startSyncing { Task { await self.syncNow() } }
        return ServerSyncConnection(
            serverName: name, baseURL: baseURL, pin: pin, deviceID: reply.device, userID: reply.user.id, role: role, imported: report
        )
    }

    /// The first address of `link` that answers, with a transport that trusts its key by the link's pin, or by the key it
    /// shows first when the link has none. Only an unreachable address moves on to the next; the last one is retried.
    private func reach(_ link: FlaccyServerLink) async throws -> (URL, any ServerSyncTransport, ServerHello) {
        let candidates = link.candidates
        for (index, url) in candidates.enumerated() {
            let transport = configuration.transports.transport(baseURL: url, token: nil, trust: .forAddress(url, pin: link.pin))
            if index == candidates.count - 1 {
                return (url, transport, try await retrying { try await transport.hello() })
            }
            do {
                return (url, transport, try await transport.hello())
            } catch let failure as ServerSyncError where failure.isUnreachable {
                log("\(url.host(percentEncoded: false) ?? "The first address") did not answer; trying the next address")
            }
        }
        throw ServerSyncError.notConnected
    }

    private func roleOfNewDevice(baseURL: URL, pin: String?, token: String, fallback: ServerRole) async -> ServerRole {
        let signedIn = configuration.transports.transport(baseURL: baseURL, token: token, trust: .forAddress(baseURL, pin: pin))
        let hello = try? await retrying { try await signedIn.hello() }
        return hello?.caller?.role ?? fallback
    }

    /// Queues the rest of what the library already holds, a bounded step at a time, so the person's own writes never wait on it.
    func importStructure(starting report: ServerSyncImportReport = ServerSyncImportReport()) async throws -> ServerSyncImportReport {
        var total = report
        while !(try store.isStructureImported()) {
            try Task.checkCancellation()
            let step = try store.importStructureStep()
            total.add(step.report)
            if step.done { break }
            await Task.yield()
        }
        return total
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
        mergeProbe = nil
        connectedBox.set(nil)
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
