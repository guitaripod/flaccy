import Foundation
import FlaccyCore

/// Scrobble-derived lookups the Songs table needs, each computed by the
/// database as an aggregate and kept until the scrobble table changes, so a
/// track change or love toggle (which reload the table) never repeats them.
nonisolated final class SongsDerivedData: @unchecked Sendable {

    private let lock = NSLock()
    private var counts: [ChartPeriod: (revision: Int, value: [String: Int])] = [:]

    func scrobbleCounts(for period: ChartPeriod) -> [String: Int] {
        let revision = LastFMStatsService.shared.scrobbleRevision
        if let cached = locked({ counts[period] }), cached.revision == revision {
            return cached.value
        }
        let fresh = LastFMStatsService.shared.scrobbleCounts(period: period)
        locked { counts[period] = (revision, fresh) }
        return fresh
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
