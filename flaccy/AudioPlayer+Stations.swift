import Foundation
import MidgarCore
import FlaccyCore

extension AudioPlayer {

    /// Builds a station of the seed artist's tracks plus similar-in-library artists
    /// (weighted by match) off the main thread, then plays from the top.
    func startStation(seedArtist: String) {
        guard !isBuildingStation else { return }
        isBuildingStation = true
        let pool = Library.shared.allTracks
        MidgarLog.info("Building artist station for \(seedArtist) from \(pool.count) library tracks", category: .playback)
        Task.detached { [weak self] in
            let pool = HideDuplicateSongsSetting.uniquePool(pool)
            let tracks = await StationBuilder.artistStation(
                seedArtist: seedArtist, pool: pool, excluding: [], limit: StationBuilder.stationSize
            )
            guard let self else { return }
            await MainActor.run { self.startBuiltStation(tracks, seedArtist: seedArtist) }
        }
    }

    /// Builds a station seeded by the track's artist, biased to place the seed track
    /// first; falls back to a plain artist station when similar data is unavailable.
    func startStation(seedTrack: Track) {
        guard !isBuildingStation else { return }
        isBuildingStation = true
        let pool = Library.shared.allTracks
        MidgarLog.info("Building track station for \(seedTrack.title) - \(seedTrack.artist)", category: .playback)
        Task.detached { [weak self] in
            let pool = HideDuplicateSongsSetting.uniquePool(pool, preferring: [seedTrack])
            let tracks = await StationBuilder.trackStation(
                seedTrack: seedTrack, pool: pool, excluding: [], limit: StationBuilder.stationSize
            )
            guard let self else { return }
            await MainActor.run { self.startBuiltStation(tracks, seedArtist: seedTrack.artist) }
        }
    }

    /// Builds a station from the user's most-played tracks (weighted by scrobble
    /// count) shuffled with variety.
    func playLibraryRadio() {
        guard !isBuildingStation else { return }
        isBuildingStation = true
        let pool = Library.shared.allTracks
        MidgarLog.info("Building library radio from \(pool.count) library tracks", category: .playback)
        Task.detached { [weak self] in
            let pool = HideDuplicateSongsSetting.uniquePool(pool)
            let counts = (try? DatabaseManager.shared.playCountByTrack()) ?? []
            let tracks = StationBuilder.libraryRadio(
                pool: pool, playCounts: counts, excluding: [], limit: StationBuilder.stationSize
            )
            guard let self else { return }
            await MainActor.run { self.startBuiltStation(tracks, seedArtist: nil) }
        }
    }

    /// Crate Dig: underplayed tracks from albums the user already loves —
    /// the deep cuts streaming can't surface because you own the full albums.
    func playCrateDig() {
        guard !isBuildingStation else { return }
        isBuildingStation = true
        let pool = Library.shared.allTracks
        MidgarLog.info("Building crate dig from \(pool.count) library tracks", category: .playback)
        Task.detached { [weak self] in
            let pool = HideDuplicateSongsSetting.uniquePool(pool)
            let counts = (try? DatabaseManager.shared.playCountByTrack()) ?? []
            let tracks = StationBuilder.crateDig(
                pool: pool, playCounts: counts, excluding: [], limit: StationBuilder.stationSize
            )
            guard let self else { return }
            await MainActor.run { self.startBuiltStation(tracks, seedArtist: nil) }
        }
    }

    func startBuiltStation(_ tracks: [Track], seedArtist: String?) {
        isBuildingStation = false
        guard !tracks.isEmpty else {
            MidgarLog.notice("Station build produced no tracks (seed \(seedArtist ?? "library"))", category: .playback)
            return
        }
        MidgarLog.info("Starting station with \(tracks.count) tracks (seed \(seedArtist ?? "library"))", category: .playback)
        engine.play(tracks, startingAt: 0, stationSeed: seedArtist)
    }

    nonisolated static func continuationBatch(_ request: ContinuationRequest) async -> [Track] {
        let pool = HideDuplicateSongsSetting.uniquePool(request.pool, preferring: request.queued)
        if let seedArtist = request.seedArtist {
            return await StationBuilder.artistStation(
                seedArtist: seedArtist, pool: pool, excluding: request.existing, limit: StationBuilder.continuationBatchSize
            )
        }
        if let seedTrack = request.seedTrack {
            return await StationBuilder.trackStation(
                seedTrack: seedTrack, pool: pool, excluding: request.existing, limit: StationBuilder.continuationBatchSize
            )
        }
        let counts = (try? DatabaseManager.shared.playCountByTrack()) ?? []
        return StationBuilder.libraryRadio(
            pool: pool, playCounts: counts, excluding: request.existing, limit: StationBuilder.continuationBatchSize
        )
    }
}
