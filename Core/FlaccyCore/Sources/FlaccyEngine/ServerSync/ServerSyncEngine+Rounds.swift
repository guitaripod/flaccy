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
            try await importEarlierListens()
            var restarts = 0
            while try await syncPass() == .restart {
                restarts += 1
                if restarts > Self.maxRestarts { throw ServerSyncError.malformed("the server kept replacing its data") }
            }
            lastFailure = nil
            publish(clockBehind ? .serverClockWrong(server: label) : upToDate())
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

    private func importEarlierListens() async throws {
        while !(try store.hasImportedListens()) {
            try Task.checkCancellation()
            if try store.importListensChunk() { break }
        }
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
                if !more { return .done }
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
        try await uploadBlobs(for: request.mutations, transport: transport)
        do {
            let response = try await retrying { try await transport.push(request, incarnation: incarnation) }
            var covers = Set<ServerCoverNeed>()
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

    private func recover(instance: String, failure: PushFailure) throws -> PushStep {
        switch try store.onPushFailure(instance: instance, failure: failure) {
        case .resend: .sent
        case .reset: .restart
        case .wait: .nothing
        }
    }

    private func uploadBlobs(for mutations: [ServerMutation], transport: any ServerSyncTransport) async throws {
        for blob in try store.blobs(for: mutations) {
            do {
                try await retrying { try await transport.putBlob(hash: blob.hash, data: blob.data, mime: Self.mime(of: blob.data)) }
            } catch let error as ServerSyncError where !error.isTransient && !error.isUnreachable {
                logError("A playlist cover was refused by the server: \(error.localizedDescription)")
            }
        }
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
