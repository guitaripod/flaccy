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

    init() {
        if !lastFM.isAuthenticated {
            importStatePublisher.send(.unavailable)
        } else if UserDefaults.standard.bool(forKey: importStateKey) {
            importStatePublisher.send(.done(imported: 0))
        }
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
                let heatmapPeriod: ChartPeriod = period == .week || period == .month ? period : .year
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
                    heatmap: stats.dayHeatmap(period: heatmapPeriod),
                    persona: stats.persona(period: period)
                )
                continuation.resume(returning: snapshot)
            }
        }
    }

    /// When local scrobbles are too sparse to fill the top lists, backfill them
    /// from Last.fm's network charts (which also carry remote album artwork) so
    /// the Recap always shows something for an authenticated user.
    private func backfillFromNetwork(_ snapshot: inout RecapData, period: ChartPeriod) async -> RecapData {
        guard lastFM.isAuthenticated else { return snapshot }
        let needArtists = snapshot.topArtists.count < 3
        let needAlbums = snapshot.topAlbums.isEmpty
        let needTracks = snapshot.topTracks.count < 3
        guard needArtists || needAlbums || needTracks else { return snapshot }

        async let netArtists = needArtists ? lastFM.fetchTopArtists(period: period, limit: 10) : []
        async let netAlbums = needAlbums ? lastFM.fetchTopAlbums(period: period, limit: 9) : []
        async let netTracks = needTracks ? lastFM.fetchTopTracks(period: period, limit: 10) : []
        let (artists, albums, tracks) = await (netArtists, netAlbums, netTracks)

        if needArtists, !artists.isEmpty {
            snapshot.topArtists = artists.enumerated().map {
                ChartArtist(rank: $0.offset + 1, name: $0.element.name, playCount: $0.element.playCount)
            }
        }
        if needAlbums, !albums.isEmpty {
            snapshot.topAlbums = albums.enumerated().map {
                ChartAlbum(rank: $0.offset + 1, name: $0.element.name, artistName: $0.element.artistName, playCount: $0.element.playCount, imageURL: $0.element.imageURL)
            }
        }
        if needTracks, !tracks.isEmpty {
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
        let baseline = stats.totalPlays(period: .allTime)
        importStatePublisher.send(.importing(imported: 0))
        AppLogger.info("Recap history import started (baseline \(baseline) scrobbles)", category: .sync)

        let progressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 800_000_000)
                guard !Task.isCancelled, let self else { return }
                let delta = max(0, self.stats.totalPlays(period: .allTime) - baseline)
                await MainActor.run {
                    if self.importStatePublisher.value.isImporting {
                        self.importStatePublisher.send(.importing(imported: delta))
                    }
                }
            }
        }

        Task { [weak self] in
            guard let self else { return }
            await self.stats.importHistory()
            progressTask.cancel()
            let imported = max(0, self.stats.totalPlays(period: .allTime) - baseline)
            UserDefaults.standard.set(true, forKey: self.importStateKey)
            AppLogger.info("Recap history import finished (\(imported) new scrobbles)", category: .sync)
            await MainActor.run {
                self.importStatePublisher.send(.done(imported: imported))
                self.load(period: self.selectedPeriod)
            }
        }
    }
}
