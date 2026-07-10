import Combine
import UIKit

/// Drives the Recap dashboard: computes a `RecapData` snapshot for the selected
/// period from local scrobbles (offline-first) enriched with the Last.fm profile,
/// and runs the one-time history import.
final class ChartsViewModel {

    let dataPublisher = CurrentValueSubject<RecapData?, Never>(nil)
    let loadingPublisher = PassthroughSubject<Bool, Never>()
    let importStatePublisher = CurrentValueSubject<RecapImportState, Never>(.available)

    private(set) var selectedPeriod: ChartPeriod = .allTime
    private(set) var data: RecapData?

    private let stats = LastFMStatsService.shared
    private let lastFM = LastFMService.shared
    private var cachedUserInfo: LastFMUserInfo?
    private var loadGeneration = 0

    private let importStateKey = "recap.historyImported"
    private var authObserver: NSObjectProtocol?

    init() {
        importStatePublisher.send(currentImportState())
        authObserver = NotificationCenter.default.addObserver(
            forName: LastFMService.authDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.handleAuthChange()
        }
    }

    deinit {
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
        if !importStatePublisher.value.isImporting {
            importStatePublisher.send(currentImportState())
        }
        load(period: selectedPeriod)
    }

    func load(period: ChartPeriod) {
        selectedPeriod = period
        loadGeneration += 1
        let generation = loadGeneration
        loadingPublisher.send(true)

        Task { [weak self] in
            guard let self else { return }
            if self.cachedUserInfo == nil, self.lastFM.isAuthenticated {
                self.cachedUserInfo = await self.lastFM.fetchUserInfo()
            }
            let snapshot = await self.buildSnapshot(period: period, userInfo: self.cachedUserInfo)
            await MainActor.run {
                guard generation == self.loadGeneration else { return }
                self.data = snapshot
                self.dataPublisher.send(snapshot)
                self.loadingPublisher.send(false)
            }
        }
    }

    private func buildSnapshot(period: ChartPeriod, userInfo: LastFMUserInfo?) async -> RecapData {
        var snapshot = await computeLocalSnapshot(period: period, userInfo: userInfo)
        return await backfillFromNetwork(&snapshot, period: period)
    }

    private func computeLocalSnapshot(period: ChartPeriod, userInfo: LastFMUserInfo?) async -> RecapData {
        let stats = self.stats
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let snapshot = RecapData(
                    userInfo: userInfo,
                    period: period,
                    totalPlays: stats.totalPlays(period: period),
                    totalMinutes: stats.totalMinutes(period: period),
                    topArtists: stats.topArtists(period: period, limit: 10),
                    topAlbums: stats.topAlbums(period: period, limit: 9),
                    topTracks: stats.topTracks(period: period, limit: 10),
                    listeningClock: stats.listeningClock(period: period),
                    streak: stats.currentStreakDays(),
                    heatmap: stats.dayHeatmap(period: period),
                    persona: stats.persona(period: period)
                )
                continuation.resume(returning: snapshot)
            }
        }
    }

    /// Replaces the ranked top lists with Last.fm's server-side period charts,
    /// which aggregate the user's entire history (the local `scrobbles` table is
    /// import-capped, so its "overall" only spans the most recent pages). Local
    /// results are retained as an offline fallback when the network returns empty.
    /// The network albums also carry remote artwork.
    private func backfillFromNetwork(_ snapshot: inout RecapData, period: ChartPeriod) async -> RecapData {
        guard lastFM.isAuthenticated else { return snapshot }

        async let netArtists = lastFM.fetchTopArtists(period: period, limit: 10)
        async let netAlbums = lastFM.fetchTopAlbums(period: period, limit: 9)
        async let netTracks = lastFM.fetchTopTracks(period: period, limit: 10)
        let (artists, albums, tracks) = await (netArtists, netAlbums, netTracks)

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
        return snapshot
    }

    /// Runs the one-time history backfill while surfacing live progress. Since
    /// `importHistory()` reports nothing itself, progress is derived by polling the
    /// local scrobble count against a pre-import baseline — the rows land in the
    /// database as pages are imported, so the delta is a real, rising count.
    func importHistory() {
        guard lastFM.isAuthenticated, !importStatePublisher.value.isImporting else { return }
        let baseline = Self.scrobbleCount()
        importStatePublisher.send(.importing(imported: 0))
        AppLogger.info("Recap history import started (baseline \(baseline) scrobbles)", category: .sync)

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
            AppLogger.info("Recap history import finished (\(imported) new scrobbles)", category: .sync)
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
