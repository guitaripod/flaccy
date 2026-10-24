import Foundation
import FlaccyCore

/// Scrobble-derived lookups the Songs table needs, each computed by the
/// database as an aggregate and kept until the scrobble table changes, so a
/// track change or love toggle (which reload the table) never repeats them.
nonisolated final class SongsDerivedData: @unchecked Sendable {

    private let lock = NSLock()
    private var counts: [ChartPeriod: (revision: Int, value: [String: Int])] = [:]
    private var rediscover: (revision: Int, day: Date, keys: [String])?

    func scrobbleCounts(for period: ChartPeriod) -> [String: Int] {
        let revision = LastFMStatsService.shared.scrobbleRevision
        if let cached = locked({ counts[period] }), cached.revision == revision {
            return cached.value
        }
        let fresh = LastFMStatsService.shared.scrobbleCounts(period: period)
        locked { counts[period] = (revision, fresh) }
        return fresh
    }

    /// Albums worth rediscovering as `albumTitle|artist` keys, from the
    /// per-album play totals and last-played times the scrobbles imply.
    func rediscoverAlbumKeys(now: Date) -> [String] {
        let revision = LastFMStatsService.shared.scrobbleRevision
        let day = Calendar.current.startOfDay(for: now)
        if let cached = locked({ rediscover }), cached.revision == revision, cached.day == day {
            return cached.keys
        }
        let rows = (try? DatabaseManager.shared.lastPlayedByAlbum()) ?? []
        let keys = LibraryFilterRules.rediscover(
            rows.map { (id: "\($0.albumTitle)|\($0.artist)", plays: $0.playCount, lastPlayed: Optional($0.lastPlayed)) },
            now: now
        )
        locked { rediscover = (revision, day, keys) }
        return keys
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
