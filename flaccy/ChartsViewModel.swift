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
            importStatePublisher.send(.done)
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

    func importHistory() {
        guard lastFM.isAuthenticated, importStatePublisher.value != .importing else { return }
        importStatePublisher.send(.importing)
        Task { [weak self] in
            guard let self else { return }
            await self.stats.importHistory()
            UserDefaults.standard.set(true, forKey: self.importStateKey)
            await MainActor.run {
                self.importStatePublisher.send(.done)
                self.load(period: self.selectedPeriod)
            }
        }
    }
}
