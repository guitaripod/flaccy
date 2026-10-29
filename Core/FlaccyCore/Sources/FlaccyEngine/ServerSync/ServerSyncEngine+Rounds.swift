import FlaccyCore
import Foundation

extension ServerSyncEngine {

    enum Flow {
        case done
        case restart
    }

    enum PushStep {
        case nothing
        case sent
        case restart
    }

    struct AccountReadOnly: Error {
        var role: ServerRole
    }

    /// Runs a sync round now, or joins the one that is running and asks for another behind it. Answers the status it ended in.
    @discardableResult
    public func syncNow() async -> SyncStatus {
        guard store.isConfigured() else {
            publish(.notConnected)
            return .notConnected
        }
        if let task = roundTask {
            rerunRequested = true
            await task.value
            return currentStatus
        }
        let task = Task { await self.runRounds() }
        roundTask = task
        await task.value
        return currentStatus
    }

    private func runRounds() async {
        repeat {
            rerunRequested = false
            await runRound()
        } while rerunRequested && !Task.isCancelled
        roundTask = nil
    }

    private func runRound() async {
        guard store.isConfigured() else { return }
        let label = serverLabel()
        let pending = (try? store.pendingCount()) ?? 0
        if !configuration.isEntitled() { return publish(.notPro) }
        if isPaused { return publish(.paused) }
        if !networkOnline { return publish(.offline(server: label, pending: pending)) }
        clockBehind = false
        publishWorking()
        do {
            try await checkRole()
            _ = try await importStructure()
            var restarts = 0
            while try await syncPass() == .restart {
                restarts += 1
                if restarts > Self.maxRestarts { throw ServerSyncError.malformed("the server kept replacing its data") }
            }
            if try await importEarlierListens() {
                while try await syncPass() == .restart {
                    restarts += 1
                    if restarts > Self.maxRestarts { throw ServerSyncError.malformed("the server kept replacing its data") }
                }
            }
            lastFailure = nil
            publish(clockBehind ? .serverClockWrong(server: label) : upToDate())
        } catch let readOnly as AccountReadOnly {
            log("The account may not write to the server any more; pending changes are kept")
            publish(SyncStatus.readOnly(role: readOnly.role, server: label) ?? .unreachable(server: label))
        } catch is CancellationError {
            log("A sync round was cancelled")
        } catch where !store.isConfigured() {
            log("A sync round ended because the server was disconnected")
        } catch let error as ServerSyncError {
            lastFailure = error
            log("A sync round stopped: \(error.localizedDescription)")
            publish(.after(failure: error, server: label, pending: (try? store.pendingCount()) ?? 0))
        } catch {
            logError("A sync round failed locally: \(error.localizedDescription)")
            publish(.after(failure: .malformed("local"), server: label, pending: (try? store.pendingCount()) ?? 0))
        }
    }

    private func upToDate() -> SyncStatus {
        let milliseconds = (try? store.lastSyncedAt()) ?? nil
        return .upToDate(lastSyncedAt: milliseconds.map { Date(timeIntervalSince1970: Double($0) / 1000) })
    }

    private func publishWorking() {
        let unsent = (try? store.unsentCount()) ?? 0
        if unsent > 0 { publish(.syncing(changes: unsent)) }
    }

    /// Asks the server who this device is now. A guest or a pending device stays quiet: nothing is sent or received, what it
    /// queued stays queued, and nothing local is touched. An account given the right to write starts recording and importing.
    private func checkRole() async throws {
        guard let link = currentLink() else { throw ServerSyncError.notConnected }
        let transport = try makeTransport(link: link)
        let hello = try await retrying { try await transport.hello() }
        guard let role = hello.caller?.role else { return }
        try store.setRole(role)
        guard role.canWrite else { throw AccountReadOnly(role: role) }
        if !store.isRecording {
            try store.refreshSongKeyIndex()
            _ = try store.beginRecording()
        }
    }

    /// Queues the person's earlier plays, a bounded step at a time. Answers true when it queued any.
    private func importEarlierListens() async throws -> Bool {
        var queuedAny = false
        try store.database.fillListenKeys()
        while !(try store.hasImportedListens()) {
            try Task.checkCancellation()
            let step = try store.importListensChunk()
            if step.queued > 0 { queuedAny = true }
            if step.done { break }
            await Task.yield()
        }
        return queuedAny
    }

    private func syncPass() async throws -> Flow {
        guard let link = currentLink() else { throw ServerSyncError.notConnected }
        let transport = try makeTransport(link: link)
        var covers = Set<ServerCoverNeed>()
        if try await pullAll(transport, covers: &covers) == .restart { return .restart }
        var pushed = false
        pushing: for _ in 0..<Self.maxPushRounds {
            switch try await pushNext(transport) {
            case .nothing: break pushing
            case .sent: pushed = true
            case .restart: return .restart
            }
        }
        if pushed, try await pullAll(transport, covers: &covers) == .restart { return .restart }
        if try await readListens(transport) == .restart { return .restart }
        try await fetchCovers(transport, covers: covers)
        return .done
    }

    private func pullAll(_ transport: any ServerSyncTransport, covers: inout Set<ServerCoverNeed>) async throws -> Flow {
        while true {
            try Task.checkCancellation()
            let request = try store.pullRequest()
            let response: ServerPullResponse
            do {
                response = try await retrying {
                    try await transport.pull(
                        since: request.since, limit: request.limit, instance: request.instance, incarnation: request.incarnation
                    )
                }
            } catch ServerSyncError.incarnationChanged(let incarnation) {
                try store.onIncarnationChanged(incarnation)
                return .restart
            } catch ServerSyncError.cookieAhead {
                _ = try store.onCookieAhead(request: request)
                return .restart
            }
            switch try store.onPullPage(request: request, response: response, localNowMs: configuration.nowMs()) {
            case .applied(let more, let outcome):
                deliver(outcome, covers: &covers)
                publishWorking()
                if !more {
                    noteFirstPullComplete()
                    return .done
                }
            case .stale:
                return .done
            case .reset:
                return .restart
            }
        }
    }

    private func pushNext(_ transport: any ServerSyncTransport) async throws -> PushStep {
        guard let request = try store.nextPush() else { return .nothing }
        let incarnation = try store.pullRequest().incarnation
        let unavailable = try await uploadBlobs(for: request.mutations, transport: transport)
        var outgoing = request
        outgoing.mutations = request.mutations.map { ReseedCovers.removing(unavailable, from: $0) }
        do {
            let response = try await retrying { try await transport.push(outgoing, incarnation: incarnation) }
            if try await keepRefusedReseeds(outgoing, response: response, transport: transport) { return .sent }
            var covers = Set<ServerCoverNeed>()
            if response.results.contains(where: { $0.code == "forbidden" }),
               let role = try await roleAfterRefusal(transport), !role.canWrite
            {
                _ = try store.onPushResponse(
                    instance: request.instance, response: response, localNowMs: configuration.nowMs(), keepForbidden: true
                )
                throw AccountReadOnly(role: role)
            }
            let outcome = try store.onPushResponse(
                instance: request.instance, response: response, localNowMs: configuration.nowMs()
            )
            deliver(outcome, covers: &covers)
            publishWorking()
            return .sent
        } catch ServerSyncError.incarnationChanged(let incarnation) {
            try store.onIncarnationChanged(incarnation)
            return .restart
        } catch ServerSyncError.instanceConflict {
            return try recover(instance: request.instance, failure: .instanceConflict)
        } catch ServerSyncError.mutationGap(let have) {
            return try recover(instance: request.instance, failure: .mutationGap(have: have))
        } catch ServerSyncError.clockBehind {
            clockBehind = true
            return .nothing
        }
    }

    private func roleAfterRefusal(_ transport: any ServerSyncTransport) async throws -> ServerRole? {
        let role = try await retrying { try await transport.hello() }.caller?.role
        if let role { try store.setRole(role) }
        return role
    }

    private func recover(instance: String, failure: PushFailure) throws -> PushStep {
        switch try store.onPushFailure(instance: instance, failure: failure) {
        case .resend: .sent
        case .reset: .restart
        case .wait: .nothing
        }
    }

    /// Uploads the cover images the mutations name. Answers the hashes that could not be uploaded, which a reseed must not name.
    private func uploadBlobs(for mutations: [ServerMutation], transport: any ServerSyncTransport) async throws -> Set<String> {
        var unavailable = Set<String>()
        for blob in try store.blobs(for: mutations) {
            guard let data = blob.data else {
                unavailable.insert(blob.hash)
                continue
            }
            do {
                try await retrying { try await transport.putBlob(hash: blob.hash, data: data, mime: Self.mime(of: data)) }
            } catch let error as ServerSyncError where !error.isTransient && !error.isUnreachable {
                logError("A playlist cover was refused by the server: \(error.localizedDescription)")
                unavailable.insert(blob.hash)
            }
        }
        return unavailable
    }

    /// A reseed the server refused over a cover is not a failure: the images are uploaded again from the local copy once, and if
    /// it is refused again the covers are left out. Answers true when it handled the answer.
    private func keepRefusedReseeds(
        _ request: ServerPushRequest, response: ServerPushResponse, transport: any ServerSyncTransport
    ) async throws -> Bool {
        let refused = Set(response.results.filter { $0.status == .invalid }.map(\.id))
        let reseeds = request.mutations.filter { $0.name == SyncPending.reseed && refused.contains($0.id) }
        guard reseeds.contains(where: { !ReseedCovers.hashes(in: $0).isEmpty }) else { return false }
        let retried = try store.hasRetriedReseedCovers()
        if !retried { _ = try await uploadBlobs(for: reseeds, transport: transport) }
        log(retried ? "The server refused the reseeded covers again; sending the base without them" : "The server refused a reseeded cover; uploading it again")
        try store.keepRefusedReseeds(
            instance: request.instance, response: response, ids: Set(reseeds.map(\.id)), removeCovers: retried
        )
        return true
    }

    private static func mime(of data: Data) -> String {
        let head = [UInt8](data.prefix(4))
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if head.starts(with: [0x52, 0x49, 0x46, 0x46]) { return "image/webp" }
        return "image/jpeg"
    }

    private func readListens(_ transport: any ServerSyncTransport) async throws -> Flow {
        var written = 0
        defer {
            noteListensMerged(written)
            if written > 0 {
                var changes = ServerSyncChanges()
                changes.listens = written
                changeHandler?(changes)
            }
        }
        while true {
            try Task.checkCancellation()
            let request = try store.listensRequest()
            let incarnation = try store.pullRequest().incarnation
            let page: ServerListensPage
            do {
                page = try await retrying {
                    try await transport.listens(
                        before: request.before, after: request.after, limit: request.limit, incarnation: incarnation
                    )
                }
            } catch ServerSyncError.incarnationChanged(let incarnation) {
                try store.onIncarnationChanged(incarnation)
                return .restart
            } catch ServerSyncError.cookieAhead {
                try store.onListensCookieAhead()
                return .restart
            }
            let wasBackfilled = try store.listensBackfilled()
            written += try store.onListensPage(page)
            if wasBackfilled && (!page.more || page.listens.isEmpty) { return .done }
        }
    }

    private func fetchCovers(_ transport: any ServerSyncTransport, covers: Set<ServerCoverNeed>) async throws {
        var changes = ServerSyncChanges()
        for need in covers.union(try store.missingCovers()) {
            try Task.checkCancellation()
            do {
                let data = try await retrying { try await transport.blob(hash: need.hash) }
                if try store.applyCover(need, data: data) { changes.playlists = true }
            } catch let error as ServerSyncError where !error.isUnreachable {
                logError("A playlist cover could not be fetched: \(error.localizedDescription)")
            }
        }
        if !changes.isEmpty { changeHandler?(changes) }
    }
}
