import FlaccyCore
import Foundation

extension ServerSyncEngine {

    /// Call once at launch: starts watching local writes, and syncs if a server is connected.
    public func launched() {
        installLocalChangeHandler()
        guard store.isConfigured() else {
            publish(.notConnected)
            return
        }
        Task { await self.syncNow() }
    }

    /// Call when the app comes to the foreground: syncs now and keeps syncing every few minutes while it stays there.
    public func foregrounded() {
        guard store.isConfigured() else { return }
        periodicTask?.cancel()
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.syncNow()
                await self.configuration.sleep(self.configuration.periodSeconds)
            }
        }
    }

    public func backgrounded() {
        periodicTask?.cancel()
        periodicTask = nil
        debounceTask?.cancel()
    }

    /// One round for a system background refresh. Cancel the surrounding task when the system's time runs out; the round stops at
    /// the next step and what it committed stays. Answers true when the server was reached and everything local is sent.
    public func performBackgroundRefresh() async -> Bool {
        guard store.isConfigured() else { return false }
        if case .upToDate = await syncNow() { return true }
        return false
    }

    /// The server's live channel announced a change in the person's scope.
    public func serverPoked() {
        Task { await self.syncNow() }
    }

    /// Feeds the network path monitor: offline stops rounds from trying, online starts one.
    public func reachabilityChanged(isOnline: Bool) {
        networkOnline = isOnline
        guard store.isConfigured() else { return }
        if isOnline {
            Task { await self.syncNow() }
        } else {
            publish(.offline(server: serverLabel(), pending: (try? store.pendingCount()) ?? 0))
        }
    }

    /// A write queued something to send. Rounds are held back a moment so a burst of writes goes out as one.
    public func localChangeRecorded() {
        guard store.isConfigured(), !isPaused, let delay = configuration.localChangeDelaySeconds else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            await self?.configuration.sleep(delay)
            guard !Task.isCancelled, let self else { return }
            await self.syncNow()
        }
    }

    func installLocalChangeHandler() {
        store.database.serverSyncGate.onRecorded { [weak self] in
            Task { await self?.localChangeRecorded() }
        }
    }

    /// Call after a library scan: re-resolves the playlist entries that waited for a file the library has now.
    public func resolveGhosts() async {
        guard store.isConfigured() else { return }
        do {
            let outcome = try store.resolveGhosts()
            var covers = Set<ServerCoverNeed>()
            deliver(outcome, covers: &covers)
        } catch {
            logError("Resolving playlist entries failed: \(error.localizedDescription)")
        }
    }

    func deliver(_ outcome: MaterializeOutcome, covers: inout Set<ServerCoverNeed>) {
        covers.formUnion(outcome.covers)
        for change in outcome.scalars {
            configuration.scalarSink?.apply(key: change.key, value: change.value)
        }
        if !outcome.changes.isEmpty { changeHandler?(outcome.changes) }
    }
}
