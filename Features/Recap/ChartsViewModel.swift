import Combine
import MidgarCore
import Foundation

/// Drives the Recap dashboard: computes a `RecapData` snapshot for the selected
/// period from local scrobbles (offline-first) enriched with the Last.fm profile,
/// and runs the one-time history import.
final class ChartsViewModel {

    let dataPublisher = CurrentValueSubject<RecapData?, Never>(nil)
    let loadingPublisher = PassthroughSubject<Bool, Never>()
    let importStatePublisher = CurrentValueSubject<RecapImportState, Never>(.available)

    private(set) var selectedPeriod: ChartPeriod
    private(set) var data: RecapData?

    private let stats = LastFMStatsService.shared
    private let lastFM = LastFMService.shared
    private var cachedUserInfo: LastFMUserInfo?
    private var loadGeneration = 0
    private var snapshotCache: [ChartPeriod: (revision: Int, data: RecapData)] = [:]

    private let importStateKey = "recap.historyImported"
    private var authObserver: NSObjectProtocol?

    init(initialPeriod: ChartPeriod = .allTime) {
        selectedPeriod = initialPeriod
        importStatePublisher.send(currentImportState())
        authObserver = NotificationCenter.default.addObserver(
            forName: LastFMService.authDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleAuthChange() }
        }
    }

    isolated deinit {
        if let authObserver {
            NotificationCenter.default.removeObserver(authObserver)
        }
    }

    private func currentImportState() -> RecapImportState {
        guard lastFM.isAuthenticated else { return .unavailable }
        return UserDefaults.standard.bool(forKey: importStateKey) ? .done(imported: 0) : .available
    }

    /// Rebuilds the Recap when a Last.fm account connects or disconnects: the
    /// profile card, network-backfilled charts, and import affordance all hinge
    /// on the account, while local stats keep rendering either way.
    private func handleAuthChange() {
        cachedUserInfo = nil
        snapshotCache.removeAll()
        if !importStatePublisher.value.isImporting {
            importStatePublisher.send(currentImportState())
        }
        load(period: selectedPeriod)
    }

    /// Shows a period as fast as the local database can answer. A snapshot seen
    /// earlier in the session is served untouched while no scrobble has been
    /// added since; otherwise the local snapshot is published the moment it is
    /// computed and the Last.fm charts upgrade it afterwards, so the network
    /// never sits in front of first paint.
    func load(period: ChartPeriod) {
        selectedPeriod = period
        loadGeneration += 1
        let generation = loadGeneration
        let revision = stats.scrobbleRevision

        if let cached = snapshotCache[period], cached.revision == revision {
            MidgarLog.debug("Recap \(period.rawValue) served from the session cache", category: .performance)
            var snapshot = cached.data
            snapshot.userInfo = cachedUserInfo ?? snapshot.userInfo
            publish(snapshot)
            loadingPublisher.send(false)
            return
        }
        loadingPublisher.send(true)

        Task { [weak self] in
            guard let self else { return }
            let local = await self.computeLocalSnapshot(period: period, userInfo: self.cachedUserInfo)
            self.snapshotCache[period] = (revision, local)
            guard generation == self.loadGeneration else { return }
            self.publish(local)
            self.loadingPublisher.send(false)
            await self.upgradeFromNetwork(local, period: period, revision: revision, generation: generation)
        }
    }

    private func publish(_ snapshot: RecapData) {
        data = snapshot
        dataPublisher.send(snapshot)
    }

    private func computeLocalSnapshot(period: ChartPeriod, userInfo: LastFMUserInfo?) async -> RecapData {
        let stats = self.stats
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let started = DispatchTime.now().uptimeNanoseconds
                let metrics = stats.recapMetrics(period: period)
                let milliseconds = (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
                MidgarLog.info(
                    "Recap \(period.rawValue) local snapshot in \(milliseconds) ms (\(metrics.totalPlays) plays)",
                    category: .performance
                )
                continuation.resume(returning: RecapData(
                    userInfo: userInfo,
                    period: period,
                    totalPlays: metrics.totalPlays,
                    totalMinutes: metrics.totalMinutes,
                    topArtists: metrics.topArtists,
                    topAlbums: metrics.topAlbums,
                    topTracks: metrics.topTracks,
                    listeningClock: metrics.listeningClock,
                    streak: metrics.streakDays,
                    heatmap: metrics.heatmap,
                    persona: metrics.persona,
                    calendarHeatmap: metrics.calendarHeatmap,
                    previousPlays: metrics.previousPlays,
                    previousMinutes: metrics.previousMinutes,
                    previousSpanDays: metrics.previousSpanDays
                ))
            }
        }
    }

    /// Replaces the ranked top lists with Last.fm's server-side period charts,
    /// which aggregate the user's entire history (the local `scrobbles` table is
    /// import-capped, so its "overall" only spans the most recent pages). Local
    /// results are retained as an offline fallback when the network returns empty.
    /// The network albums also carry remote artwork. The profile and the three
    /// charts are fetched in parallel, and the upgraded snapshot is cached for
    /// its period even if the viewer has moved on by the time it lands.
    private func upgradeFromNetwork(_ local: RecapData, period: ChartPeriod, revision: Int, generation: Int) async {
        guard lastFM.isAuthenticated else { return }

        let needsProfile = cachedUserInfo == nil
        async let netProfile: LastFMUserInfo? = needsProfile ? lastFM.fetchUserInfo() : nil
        async let netArtists = lastFM.fetchTopArtists(period: period, limit: 10)
        async let netAlbums = lastFM.fetchTopAlbums(period: period, limit: 9)
        async let netTracks = lastFM.fetchTopTracks(period: period, limit: 10)
        let (profile, artists, albums, tracks) = await (netProfile, netArtists, netAlbums, netTracks)

        if let profile { cachedUserInfo = profile }
        var snapshot = local
        snapshot.userInfo = cachedUserInfo
        if !artists.isEmpty {
            snapshot.topArtists = artists.enumerated().map {
                ChartArtist(rank: $0.offset + 1, name: $0.element.name, playCount: $0.element.playCount)
            }
        }
        if !albums.isEmpty {
            snapshot.topAlbums = albums.enumerated().map {
                ChartAlbum(rank: $0.offset + 1, name: $0.element.name, artistName: $0.element.artistName, playCount: $0.element.playCount, imageURL: $0.element.imageURL)
            }
        }
        if !tracks.isEmpty {
            snapshot.topTracks = tracks.enumerated().map {
                ChartTrack(rank: $0.offset + 1, name: $0.element.name, artistName: $0.element.artistName, playCount: $0.element.playCount)
            }
        }
        guard stats.scrobbleRevision == revision, snapshotCache[period]?.revision == revision else { return }
        snapshotCache[period] = (revision, snapshot)
        guard generation == loadGeneration else { return }
        publish(snapshot)
    }

    /// Runs the one-time history backfill while surfacing live progress. Since
    /// `importHistory()` reports nothing itself, progress is derived by polling the
    /// local scrobble count against a pre-import baseline — the rows land in the
    /// database as pages are imported, so the delta is a real, rising count.
    func importHistory() {
        guard lastFM.isAuthenticated, !importStatePublisher.value.isImporting else { return }
        let baseline = Self.scrobbleCount()
        importStatePublisher.send(.importing(imported: 0))
        MidgarLog.info("Recap history import started (baseline \(baseline) scrobbles)", category: .sync)

        let progressTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 800_000_000)
                guard !Task.isCancelled, self != nil else { return }
                let delta = max(0, Self.scrobbleCount() - baseline)
                await MainActor.run { [weak self] in
                    guard let self, self.importStatePublisher.value.isImporting else { return }
                    self.importStatePublisher.send(.importing(imported: delta))
                }
            }
        }

        Task { [weak self] in
            guard let self else { return }
            await self.stats.importHistory()
            progressTask.cancel()
            let imported = max(0, Self.scrobbleCount() - baseline)
            UserDefaults.standard.set(true, forKey: self.importStateKey)
            MidgarLog.info("Recap history import finished (\(imported) new scrobbles)", category: .sync)
            await Library.shared.reloadFromDatabase()
            await MainActor.run {
                self.importStatePublisher.send(.done(imported: imported))
                self.load(period: self.selectedPeriod)
            }
        }
    }

    /// Total scrobble count via SQL `COUNT(*)`, avoiding the O(N) full-table
    /// decode of `LastFMStatsService.totalPlays` — cheap enough to poll while
    /// the importer is writing to the same serial database queue.
    private nonisolated static func scrobbleCount() -> Int {
        (try? DatabaseManager.shared.scrobbleCountInRange(from: .distantPast, to: .distantFuture)) ?? 0
    }
}
