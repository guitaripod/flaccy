import Combine
import Foundation
import MidgarCore
import FlaccyCore
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Where the Last.fm history sync stands, in the words the screens need.
nonisolated enum ListenHistoryStatus: Hashable, Sendable {
    case notConnected
    case backfilling(plays: Int, page: Int, totalPages: Int)
    case syncing
    case synced(lastSync: Date, plays: Int)
    case failed(reason: String, lastGoodSync: Date?)

    var isBackfilling: Bool { if case .backfilling = self { true } else { false } }
    var isSyncing: Bool { if case .syncing = self { true } else { false } }

    /// Whether a sync is working right now, so a spinner belongs beside it.
    var isBusy: Bool { isBackfilling || isSyncing }

    /// The one-line description shown beside the sync control.
    var summary: String {
        switch self {
        case .notConnected:
            String(localized: "Not connected")
        case .backfilling(let plays, _, _):
            String(localized: "Bringing in your history\u{2026} \(RecapFormat.count(plays)) plays")
        case .syncing:
            String(localized: "Syncing\u{2026}")
        case .synced(let lastSync, let plays):
            String(localized: "Synced \(Self.relative(lastSync)) \u{00B7} \(RecapFormat.count(plays)) plays")
        case .failed(let reason, _):
            String(localized: "Sync paused: \(reason)")
        }
    }

    /// "2 min. ago" in the person's language.
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

/// What a finished run of the puller hands back.
nonisolated struct ListenHistoryOutcome: Sendable {
    var state: ListenHistory.SyncState
    var stored = 0
    var pages = 0
    var finishedBackfill = false
    var cancelled = false
    var failure: String?
    var reconciledRows = 0
}

/// Pulls Last.fm scrobbles into the local history, off the main actor. It owns
/// the sync state for the length of a run and persists it after every page of
/// the first full pull, so a kill resumes where it stopped.
nonisolated enum ListenHistoryPuller {

    static let pageAttempts = 4
    static let retryBackoff: Duration = .milliseconds(800)

    @concurrent
    static func run(
        from start: ListenHistory.SyncState,
        db: DatabaseManager,
        lastFM: LastFMService,
        progress: @escaping @Sendable (ListenHistoryStatus) -> Void
    ) async -> ListenHistoryOutcome {
        var outcome = ListenHistoryOutcome(state: start)
        let began = DispatchTime.now().uptimeNanoseconds
        do {
            try await pull(&outcome, db: db, lastFM: lastFM, progress: progress)
            if outcome.stored > 0 || outcome.finishedBackfill {
                outcome.reconciledRows = (try? db.reconcilePlayCountsFromScrobbles()) ?? 0
            }
        } catch is CancellationError {
            outcome.cancelled = true
        } catch {
            outcome.failure = error.localizedDescription
            MidgarLog.error("Last.fm history sync failed: \(error.localizedDescription)", category: .sync)
        }
        let milliseconds = (DispatchTime.now().uptimeNanoseconds - began) / 1_000_000
        MidgarLog.info(
            "Last.fm history sync pages=\(outcome.pages) stored=\(outcome.stored) reconciled=\(outcome.reconciledRows) in \(milliseconds) ms",
            category: .sync
        )
        return outcome
    }

    private static func pull(
        _ outcome: inout ListenHistoryOutcome,
        db: DatabaseManager,
        lastFM: LastFMService,
        progress: @Sendable (ListenHistoryStatus) -> Void
    ) async throws {
        let firstStep = outcome.state.nextStep(now: nowSeconds)
        var ledger = ListenHistory.Ledger(try db.storedListens(since: ledgerStart(for: firstStep)))
        while true {
            try Task.checkCancellation()
            let step = outcome.state.nextStep(now: nowSeconds)
            switch step {
            case .backfill(let page, let anchor):
                try await backfill(page: page, anchor: anchor, &outcome, ledger: &ledger, db: db, lastFM: lastFM, progress: progress)
            case .catchUp(let from), .settle(let from):
                try await pullRange(from: from, step: step, &outcome, ledger: &ledger, db: db, lastFM: lastFM)
                return
            }
        }
    }

    private static var nowSeconds: Int { Int(Date().timeIntervalSince1970) }

    /// A first full pull dedups against the whole history; a range pull only
    /// against the plays from just before its start.
    private static func ledgerStart(for step: ListenHistory.Step) -> Date {
        switch step {
        case .backfill: .distantPast
        case .catchUp(let from), .settle(let from): Date(timeIntervalSince1970: TimeInterval(from - 1))
        }
    }

    private static func backfill(
        page: Int,
        anchor: Int,
        _ outcome: inout ListenHistoryOutcome,
        ledger: inout ListenHistory.Ledger,
        db: DatabaseManager,
        lastFM: LastFMService,
        progress: @Sendable (ListenHistoryStatus) -> Void
    ) async throws {
        let fetched = try await fetchPage(page: page, from: nil, to: anchor, lastFM: lastFM)
        let admitted = try store(fetched.tracks, ledger: &ledger, db: db)
        outcome.stored += admitted.stored
        outcome.pages += 1
        outcome.state.recordBackfillPage(
            page: page, totalPages: fetched.totalPages, anchor: anchor, newest: admitted.newest, now: nowSeconds
        )
        try db.saveListenSyncState(outcome.state)
        if outcome.state.backfillComplete {
            outcome.finishedBackfill = true
        }
        let plays = (try? db.scrobbleCountInRange(from: .distantPast, to: .distantFuture)) ?? 0
        progress(.backfilling(plays: plays, page: page, totalPages: fetched.totalPages))
    }

    /// Reads every page from `from` on, newest first, and records the pull only
    /// once all of them arrived: a gap must never be skipped, and rows already
    /// stored by a pull that failed are harmless because dedup drops them.
    private static func pullRange(
        from: Int,
        step: ListenHistory.Step,
        _ outcome: inout ListenHistoryOutcome,
        ledger: inout ListenHistory.Ledger,
        db: DatabaseManager,
        lastFM: LastFMService
    ) async throws {
        var newest: Int?
        var page = 1
        var totalPages = 1
        while page <= totalPages {
            try Task.checkCancellation()
            let fetched = try await fetchPage(page: page, from: from, to: nil, lastFM: lastFM)
            totalPages = fetched.totalPages
            let admitted = try store(fetched.tracks, ledger: &ledger, db: db)
            outcome.stored += admitted.stored
            outcome.pages += 1
            newest = [newest, admitted.newest].compactMap { $0 }.max()
            page += 1
        }
        outcome.state.recordPull(step, newest: newest, now: nowSeconds)
        try db.saveListenSyncState(outcome.state)
    }

    /// Stores the scrobbles of one page that the ledger admits, and reports the
    /// newest time on the page whether or not it was new.
    private static func store(
        _ tracks: [RecentTrack],
        ledger: inout ListenHistory.Ledger,
        db: DatabaseManager
    ) throws -> (stored: Int, newest: Int?) {
        var rows: [DatabaseManager.PulledListen] = []
        var newest: Int?
        for track in tracks {
            guard let timestamp = track.uts else { continue }
            newest = max(newest ?? timestamp, timestamp)
            let keys = ListenHistory.Keys(title: track.name, artist: track.artist, album: track.album)
            guard ledger.admit(timestamp: timestamp, keys: keys) else { continue }
            rows.append(DatabaseManager.PulledListen(
                title: track.name, artist: track.artist, album: track.album,
                timestamp: Date(timeIntervalSince1970: TimeInterval(timestamp))
            ))
        }
        return (stored: try db.insertPulledListens(rows), newest: newest)
    }

    /// One page, retried with a growing pause: Last.fm answers long pulls with
    /// the occasional "backend service failed" that the next try gets past.
    private static func fetchPage(
        page: Int, from: Int?, to: Int?, lastFM: LastFMService
    ) async throws -> (tracks: [RecentTrack], totalPages: Int) {
        var attempt = 1
        while true {
            do {
                let result = try await lastFM.fetchRecentTracks(page: page, limit: 200, from: from, to: to)
                return (result.tracks, result.totalPages)
            } catch {
                try Task.checkCancellation()
                guard attempt < pageAttempts else { throw error }
                try await Task.sleep(for: retryBackoff * attempt)
                attempt += 1
            }
        }
    }
}

/// Keeps the person's Last.fm history flowing into the local `scrobbles` table:
/// a first full pull, then catch-up pulls on launch, on focus and on a timer.
/// It owns the persisted sync state, publishes a status for the screens and
/// posts `didChange` when new plays were stored.
@MainActor
final class ListenHistorySync {

    static let shared = ListenHistorySync()

    static let didChange = Notification.Name("ListenHistorySyncDidChange")

    static let legacyImportFlagKey = "recap.historyImported"

    let statusPublisher = CurrentValueSubject<ListenHistoryStatus, Never>(.notConnected)

    private let db = DatabaseManager.shared
    private let lastFM = LastFMService.shared
    private var state = ListenHistory.SyncState()
    private var stateAccount: String?
    private var syncTask: Task<Void, Never>?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var started = false
    private var knownTotalPages = 0
    private var generation = 0

    private init() {}

    var status: ListenHistoryStatus { statusPublisher.value }

    /// Whether the first full pull of the connected account has finished, so
    /// the local history can stand in for Last.fm's own charts.
    var backfillComplete: Bool {
        loadStateIfNeeded()
        return lastFM.isAuthenticated && state.backfillComplete
    }

    /// Begins syncing and keeps going: call once at launch, after the pending
    /// scrobbles have been drained.
    func start() {
        guard !started else { return }
        started = true
        observeTriggers()
        if isApplicationActive { schedulePeriodicSync() }
        refreshForAccount()
        syncIfDue()
    }

    /// An automatic trigger: launch, focus or the timer. Skips when a sync ran
    /// a moment ago.
    func syncIfDue() {
        guard lastFM.isAuthenticated else { return }
        loadStateIfNeeded()
        guard state.automaticSyncDue(now: Self.nowSeconds) else { return }
        beginSync()
    }

    /// The person asked for a sync: runs whatever the spacing says.
    func syncNow() {
        guard lastFM.isAuthenticated else { return }
        loadStateIfNeeded()
        beginSync()
    }

    private static var nowSeconds: Int { Int(Date().timeIntervalSince1970) }

    private func beginSync() {
        guard syncTask == nil else { return }
        #if DEBUG
        if CommandLine.arguments.contains("--memory-audit") || CommandLine.arguments.contains("--skip-keychain") {
            return
        }
        #endif
        statusPublisher.send(state.backfillComplete ? .syncing : .backfilling(plays: storedPlays(), page: state.backfillPage, totalPages: knownTotalPages))
        let start = state
        let db = self.db
        let lastFM = self.lastFM
        generation += 1
        let mine = generation
        syncTask = Task { [weak self] in
            let outcome = await ListenHistoryPuller.run(from: start, db: db, lastFM: lastFM) { status in
                Task { @MainActor in self?.receiveProgress(status, generation: mine) }
            }
            await self?.finish(outcome, generation: mine)
        }
    }

    /// A page's progress, dropped when it arrives after its sync finished so
    /// a late "bringing in" can never cover the final status.
    private func receiveProgress(_ status: ListenHistoryStatus, generation: Int) {
        guard generation == self.generation, syncTask != nil else { return }
        if case .backfilling(_, _, let totalPages) = status { knownTotalPages = totalPages }
        statusPublisher.send(status)
    }

    private func finish(_ outcome: ListenHistoryOutcome, generation: Int) async {
        guard generation == self.generation else { return }
        syncTask = nil
        guard lastFM.isAuthenticated, stateAccount == outcome.state.account else {
            publishNotConnectedOrIdle()
            return
        }
        state = outcome.state
        if outcome.cancelled {
            publishIdleStatus()
            return
        }
        if outcome.reconciledRows > 0 {
            await Library.shared.reloadFromDatabase()
        }
        if let failure = outcome.failure {
            statusPublisher.send(.failed(reason: failure, lastGoodSync: state.lastSyncAt.map(Self.date)))
        } else {
            publishIdleStatus()
        }
        if outcome.stored > 0 || outcome.finishedBackfill {
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        }
    }

    private func publishNotConnectedOrIdle() {
        if lastFM.isAuthenticated {
            refreshForAccount()
        } else {
            statusPublisher.send(.notConnected)
        }
    }

    private func publishIdleStatus() {
        guard lastFM.isAuthenticated else {
            statusPublisher.send(.notConnected)
            return
        }
        if state.backfillComplete {
            statusPublisher.send(.synced(lastSync: state.lastSyncAt.map(Self.date) ?? Date(), plays: storedPlays()))
        } else {
            statusPublisher.send(.backfilling(plays: storedPlays(), page: state.backfillPage, totalPages: knownTotalPages))
        }
    }

    private static func date(_ seconds: Int) -> Date {
        Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    private func storedPlays() -> Int {
        (try? db.scrobbleCountInRange(from: .distantPast, to: .distantFuture)) ?? 0
    }

    private func loadStateIfNeeded() {
        guard let account = lastFM.username, lastFM.isAuthenticated else { return }
        guard stateAccount != account else { return }
        stateAccount = account
        knownTotalPages = 0
        if let saved = try? db.listenSyncState(account: account) {
            state = saved
            return
        }
        state = initialState(account: account)
        do {
            try db.saveListenSyncState(state)
        } catch {
            MidgarLog.error("Saving the first history sync state failed: \(error.localizedDescription)", category: .sync)
        }
    }

    /// The state an account starts from. A person whose earlier build imported
    /// the history by hand keeps it, provided the plays it brought are still in
    /// the database; anyone else starts the first full pull.
    private func initialState(account: String) -> ListenHistory.SyncState {
        let newestImported = try? db.newestPulledListen()
        let importedBefore = UserDefaults.standard.bool(forKey: Self.legacyImportFlagKey) && newestImported != nil
        guard importedBefore else { return ListenHistory.SyncState().forAccount(account) }
        return ListenHistory.SyncState.adopting(
            account: account,
            legacyComplete: true,
            legacyPage: 1,
            newestImported: newestImported.map { Int($0.timeIntervalSince1970) },
            now: Self.nowSeconds
        )
    }

    private func refreshForAccount() {
        guard lastFM.isAuthenticated else {
            statusPublisher.send(.notConnected)
            return
        }
        loadStateIfNeeded()
        publishIdleStatus()
    }

    private func handleAuthChange() {
        syncTask?.cancel()
        syncTask = nil
        generation += 1
        stateAccount = nil
        state = ListenHistory.SyncState()
        guard lastFM.isAuthenticated else {
            statusPublisher.send(.notConnected)
            NotificationCenter.default.post(name: Self.didChange, object: nil)
            return
        }
        refreshForAccount()
        beginSync()
    }

    private func observeTriggers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: LastFMService.authDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleAuthChange() }
        })
        observers.append(center.addObserver(forName: Self.didBecomeActiveName, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.schedulePeriodicSync()
                self?.syncIfDue()
            }
        })
        observers.append(center.addObserver(forName: Self.willResignActiveName, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelPeriodicSync() }
        })
    }

    private func schedulePeriodicSync() {
        timer?.invalidate()
        let interval = TimeInterval(ListenHistory.periodicSync)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncIfDue() }
        }
    }

    private func cancelPeriodicSync() {
        timer?.invalidate()
        timer = nil
    }

    #if canImport(UIKit)
    private static let didBecomeActiveName = UIApplication.didBecomeActiveNotification
    private static let willResignActiveName = UIApplication.willResignActiveNotification
    private var isApplicationActive: Bool { UIApplication.shared.applicationState == .active }
    #else
    private static let didBecomeActiveName = NSApplication.didBecomeActiveNotification
    private static let willResignActiveName = NSApplication.willResignActiveNotification
    private var isApplicationActive: Bool { NSApplication.shared.isActive }
    #endif
}
