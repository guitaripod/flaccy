import Combine
import FlaccyCore
import MidgarCore
import Foundation

/// Drives the Recap dashboard: computes a `RecapData` snapshot for the selected
/// period from local scrobbles (offline-first) enriched with the Last.fm profile.
/// The scrobbles themselves arrive through `ListenHistorySync`.
final class ChartsViewModel {

    let dataPublisher = CurrentValueSubject<RecapData?, Never>(nil)
    let loadingPublisher = PassthroughSubject<Bool, Never>()

    var syncStatusPublisher: CurrentValueSubject<ListenHistoryStatus, Never> { ListenHistorySync.shared.statusPublisher }

    private(set) var selectedPeriod: ChartPeriod
    private(set) var data: RecapData?

    private let stats = LastFMStatsService.shared
    private let lastFM = LastFMService.shared
    private var cachedUserInfo: LastFMUserInfo?
    private var loadGeneration = 0
    private var snapshotCache: [ChartPeriod: (revision: Int, data: RecapData)] = [:]

    private var observers: [NSObjectProtocol] = []

    init(initialPeriod: ChartPeriod = .allTime) {
        selectedPeriod = initialPeriod
        observers.append(NotificationCenter.default.addObserver(
            forName: LastFMService.authDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleAuthChange() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: ListenHistorySync.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleHistoryChange() }
        })
    }

    isolated deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Rebuilds the Recap when a Last.fm account connects or disconnects: the
    /// profile card and the sync banner hinge on the account, while local
    /// stats keep rendering either way.
    private func handleAuthChange() {
        cachedUserInfo = nil
        snapshotCache.removeAll()
        load(period: selectedPeriod)
    }

    /// Redraws the visible period when the sync stored new plays: the snapshot
    /// cache keys on the scrobble revision, so only a changed history recomputes.
    private func handleHistoryChange() {
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

    /// Adds what the network knows to a local snapshot. The profile is always
    /// fetched. While the first full pull of the history is still running the
    /// local charts are partial, so Last.fm's server-side period charts stand
    /// in for them (the local lists stay as the offline fallback when the
    /// network returns empty). Once the history is complete the lists stay
    /// local, and Last.fm's top albums only lend their artwork to local
    /// entries the library does not own. The upgraded snapshot is cached for
    /// its period even if the viewer has moved on by the time it lands.
    private func upgradeFromNetwork(_ local: RecapData, period: ChartPeriod, revision: Int, generation: Int) async {
        guard lastFM.isAuthenticated else { return }

        let historyIsLocal = ListenHistorySync.shared.backfillComplete
        let needsProfile = cachedUserInfo == nil
        async let netProfile: LastFMUserInfo? = needsProfile ? lastFM.fetchUserInfo() : nil
        async let netArtists: [ChartArtist] = historyIsLocal ? [] : lastFM.fetchTopArtists(period: period, limit: 10)
        async let netAlbums: [ChartAlbum] = lastFM.fetchTopAlbums(period: period, limit: historyIsLocal ? 50 : 9)
        async let netTracks: [ChartTrack] = historyIsLocal ? [] : lastFM.fetchTopTracks(period: period, limit: 10)
        let (profile, artists, albums, tracks) = await (netProfile, netArtists, netAlbums, netTracks)

        if let profile { cachedUserInfo = profile }
        var snapshot = local
        snapshot.userInfo = cachedUserInfo
        if historyIsLocal {
            snapshot.topAlbums = Self.lendingArtwork(from: albums, to: snapshot.topAlbums)
        } else {
            replaceTopLists(in: &snapshot, artists: artists, albums: albums, tracks: tracks)
        }
        guard stats.scrobbleRevision == revision, snapshotCache[period]?.revision == revision else { return }
        snapshotCache[period] = (revision, snapshot)
        guard generation == loadGeneration else { return }
        publish(snapshot)
    }

    private func replaceTopLists(in snapshot: inout RecapData, artists: [ChartArtist], albums: [ChartAlbum], tracks: [ChartTrack]) {
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
    }

    /// Copies Last.fm's cover URL onto each local album it describes: the same
    /// release and lead artist under the shared listen keys.
    private static func lendingArtwork(from remote: [ChartAlbum], to local: [ChartAlbum]) -> [ChartAlbum] {
        var artwork: [String: String] = [:]
        for album in remote {
            guard let imageURL = album.imageURL else { continue }
            artwork[artworkKey(album)] = artwork[artworkKey(album)] ?? imageURL
        }
        return local.map { album in
            guard album.imageURL == nil, let imageURL = artwork[artworkKey(album)] else { return album }
            return ChartAlbum(rank: album.rank, name: album.name, artistName: album.artistName, playCount: album.playCount, imageURL: imageURL)
        }
    }

    private static func artworkKey(_ album: ChartAlbum) -> String {
        ListenHistory.albumKey(album.name) + "\u{0}" + ListenHistory.artistKey(album.artistName)
    }
}
