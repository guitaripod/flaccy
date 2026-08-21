import Foundation
import Network

/// Drains the durable enrichment queue.
///
/// There is no in-memory cursor anywhere in here: the `enrichmentState` rows
/// *are* the cursor, so a force-quit mid-pass costs nothing and a relaunch
/// resumes from exactly where it stopped. Everything the job reports is either
/// a `count(*)` over the queue's own predicate or a counter for this run — it
/// never claims a percentage, because the work is unbounded.
actor EnrichmentCoordinator {

    static let shared = EnrichmentCoordinator()

    static let progressDidChange = Notification.Name("EnrichmentJobProgressChanged")

    /// Posted when one album gained metadata, so a surface can repaint that one
    /// tile instead of reloading the library under the reader.
    static let albumDidEnrich = Notification.Name("EnrichmentAlbumDidEnrich")

    enum ProgressKey {
        static let progress = "progress"
        static let title = "title"
        static let artist = "artist"
    }

    /// How many entities are in flight at once on an unmetered connection.
    private static let maxConcurrency = 3

    /// How many the job allows itself on a metered or Low Data connection.
    private static let meteredConcurrency = 1

    private static let pageSize = 64
    private static let publishInterval: TimeInterval = 0.25

    /// AI first: identification renames albums, and a renamed album is a new
    /// key, so finding artwork for the old one would be work thrown away.
    private static let scopeOrder: [EnrichmentScope] = [.aiBatch, .album, .artist]

    private let state = ProgressBox()
    private let network = NetworkWatch()

    nonisolated var progress: EnrichmentJobProgress { state.value }

    private var run: Task<Void, Never>?
    private var rerunRequested = false
    private var networkResume: Task<Void, Never>?

    private var lastPublish: Date = .distantPast
    private var pendingPublish: Task<Void, Never>?

    private var completedThisRun = 0
    private var startedAt: Date?
    private var consecutiveTransportFailures = 0

    private init() {}

    /// Starts a pass, or asks the one already running to go round again once it
    /// finishes. Cheap to call on every reload: a pass that finds nothing due
    /// costs one `count(*)` per scope and raises no surface at all.
    func resume() {
        network.start()
        guard run == nil else {
            rerunRequested = true
            return
        }
        run = Task { [weak self] in
            await self?.drainEverything()
        }
    }

    /// Enriches one album on behalf of somebody looking at it, jumping it to the
    /// front of the durable queue. `force` is for an explicit user command only:
    /// it skips `EnrichmentPolicy.isDue` — and therefore the terminal
    /// `exhausted` cache — but never the "already has everything" test. Passive
    /// arrival on a page takes the default, so browsing can never burn the
    /// four-attempt ladder. Returns whether the album's metadata actually
    /// changed; a caller that needs to tell "no source has this" from "we could
    /// not reach any source" reads `lastFailure` off the persisted record.
    func requestNow(title: String, artist: String, force: Bool = false) async -> Bool {
        let outcome = await EnrichmentTasks.run(.album(title: title, artist: artist), force: force)
        guard outcome.changedLibrary else { return false }
        await AppLogger.info("Enriched on request: \(artist) — \(title)", category: .content)
        announce(title: title, artist: artist)
        return true
    }

    /// Requeues everything the job gave up on and starts a pass. The resolved
    /// fields survive, so a retry only chases what is still missing.
    func retryExhausted(scope: EnrichmentScope) {
        let revived = (try? DatabaseManager.shared.resetExhausted(scope: scope)) ?? 0
        log("Requeued \(revived) exhausted \(scope.rawValue) entities")
        guard revived > 0 else { return }
        resume()
    }

    private func drainEverything() async {
        startedAt = Date()
        completedThisRun = 0

        repeat {
            rerunRequested = false
            for scope in Self.scopeOrder {
                guard !Task.isCancelled else { break }
                await drain(scope: scope)
            }
        } while rerunRequested && !Task.isCancelled

        run = nil
        startedAt = nil
        if !holdsItsLastReport { publish(.idle) }
        flushPublish()
    }

    /// Whether the pass ended owing the reader an explanation it must keep on
    /// screen. A parked pass resumes itself once the reason clears, so calling
    /// it idle would hide "waiting for a connection" behind nothing at all.
    private var holdsItsLastReport: Bool {
        state.value.activity == .waitingForNetwork || state.value.activity == .needsEntitlement
    }

    /// Drains one scope a page at a time. `attempted` is what makes this loop
    /// terminate when nothing is reachable: an entity a transport failure left
    /// pending is still due, so without it the same 64 rows would come back
    /// forever.
    ///
    /// The pass reports the scope's true `remaining` before it reads the page,
    /// because the read itself can outlast the debut's finishing act on a large
    /// library — and an act that has never heard from the job holds rather than
    /// mistaking silence for a drained queue.
    private func drain(scope: EnrichmentScope) async {
        let db = DatabaseManager.shared
        var attempted = Set<String>()
        consecutiveTransportFailures = 0

        while !Task.isCancelled {
            let version = scope.currentVersion
            let now = Date()

            let remaining = (try? db.countDue(scope: scope, version: version, now: now)) ?? 0
            guard remaining > 0 else { return }
            let exhausted = (try? db.countExhausted(scope: scope)) ?? 0

            let reachability = network.reachability
            guard reachability.satisfied else {
                publish(waitingForNetwork(scope: scope, remaining: remaining, exhausted: exhausted))
                armNetworkResume(after: reachability.generation)
                return
            }

            publish(running(scope: scope, remaining: remaining, exhausted: exhausted, title: nil))

            let page = entities(scope: scope, version: version, now: now)
                .filter { !attempted.contains($0.key) }
            guard !page.isEmpty else { return }
            for entity in page { attempted.insert(entity.key) }

            let stopped = await process(page, scope: scope, remaining: remaining, exhausted: exhausted)
            if stopped { return }
        }
    }

    /// Runs one page with a bounded task group, refilling as each entity
    /// finishes rather than waiting for the slowest. Returns true when the scope
    /// should stop for this run.
    private func process(
        _ page: [EnrichmentEntity], scope: EnrichmentScope, remaining: Int, exhausted: Int
    ) async -> Bool {
        let limit = network.isRestricted ? Self.meteredConcurrency : Self.maxConcurrency
        let byKey = Dictionary(page.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var left = remaining
        var stop = false

        await withTaskGroup(of: EnrichmentTaskOutcome.self) { group in
            var next = 0

            while next < min(limit, page.count) {
                let entity = page[next]
                next += 1
                publish(running(scope: scope, remaining: left, exhausted: exhausted, title: entity.displayTitle))
                group.addTask { await EnrichmentTasks.run(entity) }
            }

            for await outcome in group {
                if outcome.attempted, outcome.settled {
                    completedThisRun += 1
                    left = max(0, left - 1)
                }
                if outcome.changedLibrary, case .album(let title, let artist)? = byKey[outcome.key] {
                    announce(title: title, artist: artist)
                }

                switch outcome.failure {
                case .transport:
                    consecutiveTransportFailures += 1
                case .unauthorized:
                    stop = true
                    publish(needsEntitlement(scope: scope, remaining: left, exhausted: exhausted))
                default:
                    consecutiveTransportFailures = 0
                }

                if consecutiveTransportFailures >= EnrichmentPolicy.transportFailuresBeforeWaiting {
                    stop = true
                    publish(waitingForNetwork(scope: scope, remaining: left, exhausted: exhausted))
                    armNetworkResume(after: network.reachability.generation)
                } else if !stop {
                    publish(running(scope: scope, remaining: left, exhausted: exhausted, title: outcome.title))
                }

                guard !stop, next < page.count else { continue }
                let entity = page[next]
                next += 1
                group.addTask { await EnrichmentTasks.run(entity) }
            }
        }

        return stop
    }

    /// Builds this page's entities. Albums and artists are named by the queue
    /// query; an AI batch additionally needs its tracks, which are read once per
    /// page and grouped exactly the way `enrichmentState` keys them.
    private func entities(scope: EnrichmentScope, version: Int, now: Date) -> [EnrichmentEntity] {
        let db = DatabaseManager.shared
        switch scope {
        case .album:
            let keys = (try? db.dueAlbumKeys(version: version, now: now, limit: Self.pageSize)) ?? []
            return keys.map { .album(title: $0.title, artist: $0.artist) }
        case .artist:
            let names = (try? db.dueArtistNames(version: version, now: now, limit: Self.pageSize)) ?? []
            return names.map { .artist(name: $0) }
        case .aiBatch:
            let directories = (try? db.dueAIBatchDirectories(version: version, now: now, limit: Self.pageSize)) ?? []
            guard !directories.isEmpty else { return [] }
            let unanalyzed = ((try? db.fetchAllTracks()) ?? []).filter { !$0.aiAnalyzed }
            let grouped = Dictionary(grouping: unanalyzed) { Self.directory(of: $0.fileURL) }
            return directories.compactMap { directory in
                guard let tracks = grouped[directory], !tracks.isEmpty else { return nil }
                return .aiBatch(directory: directory, tracks: tracks)
            }
        }
    }

    /// The parent path with no trailing slash, or "" for a track sitting at the
    /// library root — the same grouping the v10 seed computes in SQL.
    private static func directory(of relativePath: String) -> String {
        let components = relativePath.split(separator: "/")
        return components.count > 1 ? components.dropLast().joined(separator: "/") : ""
    }

    private nonisolated func announce(title: String, artist: String) {
        Task { @MainActor in
            NotificationCenter.default.post(
                name: Self.albumDidEnrich, object: nil,
                userInfo: [ProgressKey.title: title, ProgressKey.artist: artist]
            )
        }
    }

    private func running(
        scope: EnrichmentScope, remaining: Int, exhausted: Int, title: String?
    ) -> EnrichmentJobProgress {
        EnrichmentJobProgress(
            activity: .running, scope: scope, remaining: remaining,
            completedThisRun: completedThisRun, exhausted: exhausted,
            currentTitle: title, startedAt: startedAt
        )
    }

    private func waitingForNetwork(
        scope: EnrichmentScope, remaining: Int, exhausted: Int
    ) -> EnrichmentJobProgress {
        EnrichmentJobProgress(
            activity: .waitingForNetwork, scope: scope, remaining: remaining,
            completedThisRun: completedThisRun, exhausted: exhausted,
            currentTitle: nil, startedAt: startedAt
        )
    }

    private func needsEntitlement(
        scope: EnrichmentScope, remaining: Int, exhausted: Int
    ) -> EnrichmentJobProgress {
        EnrichmentJobProgress(
            activity: .needsEntitlement, scope: scope, remaining: remaining,
            completedThisRun: completedThisRun, exhausted: exhausted,
            currentTitle: nil, startedAt: startedAt
        )
    }

    /// Suspends the job until the path monitor reports a route it has not
    /// already failed against, then starts a fresh pass. Nothing durable was
    /// written for the items that failed, so the queue is unchanged. The
    /// generation is sampled by the caller *before* it decides to wait, so a
    /// satisfied path landing in the gap resumes the job instead of being lost.
    private func armNetworkResume(after generation: UInt64) {
        guard networkResume == nil else { return }
        networkResume = Task { [network] in
            await network.waitForNewSatisfiedPath(after: generation)
            await EnrichmentCoordinator.shared.networkReturned()
        }
    }

    private func networkReturned() {
        networkResume = nil
        consecutiveTransportFailures = 0
        log("Network returned; resuming enrichment")
        resume()
    }

    private nonisolated func log(_ message: String) {
        Task { await AppLogger.info(message, category: .content) }
    }

    /// Publishes at most once every 0.25 s. The snapshot is written to the box
    /// synchronously so `progress` is always current; the notification is
    /// delivered on the main actor and re-reads the box, so a late delivery can
    /// only ever carry *newer* state, never stale state.
    private func publish(_ next: EnrichmentJobProgress) {
        state.value = next

        let now = Date()
        let elapsed = now.timeIntervalSince(lastPublish)
        guard elapsed >= Self.publishInterval else {
            schedulePublish(in: Self.publishInterval - elapsed)
            return
        }
        pendingPublish?.cancel()
        pendingPublish = nil
        lastPublish = now
        postLatest()
    }

    private func schedulePublish(in delay: TimeInterval) {
        guard pendingPublish == nil else { return }
        pendingPublish = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.flushPublish()
        }
    }

    private func flushPublish() {
        pendingPublish = nil
        lastPublish = Date()
        postLatest()
    }

    private nonisolated func postLatest() {
        let box = state
        Task { @MainActor in
            NotificationCenter.default.post(
                name: Self.progressDidChange, object: nil, userInfo: [ProgressKey.progress: box.value]
            )
        }
    }
}

/// The job's published snapshot, readable from any thread without awaiting the
/// actor — a view that is rendering cannot afford to suspend to ask.
private nonisolated final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: EnrichmentJobProgress = .idle

    var value: EnrichmentJobProgress {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// Wraps `NWPathMonitor` so the coordinator can both sample the current path
/// and suspend until a *new* satisfied one arrives. Waiting for the next update
/// rather than for `.satisfied` is what stops a captive portal — which reports a
/// perfectly satisfied path while answering every request with a login page —
/// from spinning the job.
private nonisolated final class NetworkWatch: @unchecked Sendable {

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.midgarcorp.flaccy.enrichment.network")
    private let lock = NSLock()
    private var started = false
    private var satisfied = true
    private var restricted = false
    private var satisfiedGeneration: UInt64 = 0
    private var waiters: [(generation: UInt64, continuation: CheckedContinuation<Void, Never>)] = []

    /// Reachability and the number of satisfied path updates seen so far, read
    /// together so a caller that decides to wait cannot miss an update landing
    /// between the two reads.
    var reachability: (satisfied: Bool, generation: UInt64) {
        lock.withLock { (satisfied, satisfiedGeneration) }
    }

    var isRestricted: Bool { lock.withLock { restricted } }

    func start() {
        let shouldStart: Bool = lock.withLock {
            guard !started else { return false }
            started = true
            return true
        }
        guard shouldStart else { return }

        monitor.pathUpdateHandler = { [weak self] path in
            self?.apply(path)
        }
        monitor.start(queue: queue)
    }

    /// Returns once a satisfied path has arrived since `generation`. A caller
    /// that already missed one returns immediately; one that is still current
    /// parks, so a stable captive-portal route — which never advances the
    /// generation — cannot spin the job.
    func waitForNewSatisfiedPath(after generation: UInt64) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let alreadyMoved: Bool = lock.withLock {
                guard satisfiedGeneration == generation else { return true }
                waiters.append((generation, continuation))
                return false
            }
            if alreadyMoved { continuation.resume() }
        }
    }

    private func apply(_ path: NWPath) {
        let isSatisfied = path.status == .satisfied
        let resumable: [CheckedContinuation<Void, Never>] = lock.withLock {
            satisfied = isSatisfied
            restricted = path.isExpensive || path.isConstrained
            guard isSatisfied else { return [] }
            satisfiedGeneration &+= 1
            let pending = waiters.map(\.continuation)
            waiters.removeAll()
            return pending
        }
        for continuation in resumable { continuation.resume() }
    }
}
