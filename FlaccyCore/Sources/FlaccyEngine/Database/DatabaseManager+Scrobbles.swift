import Foundation
import MidgarCore
import FlaccyCore
import GRDB

extension DatabaseManager {

    public func insertScrobble(_ scrobble: ScrobbleRecord) throws {
        try dbQueue.write { db in
            try scrobble.insert(db)
        }
        scrobbleRevisionCounter.bump()
    }

    /// Inserts a whole batch in one transaction, so a Last.fm page costs one
    /// commit rather than one per row.
    public func insertScrobbles(_ scrobbles: [ScrobbleRecord]) throws {
        guard !scrobbles.isEmpty else { return }
        try dbQueue.write { db in
            for scrobble in scrobbles {
                try scrobble.insert(db)
            }
        }
        scrobbleRevisionCounter.bump()
    }

    /// Changes whenever a scrobble is added or the table is emptied, so a
    /// cache built from the scrobbles can tell in one integer compare whether
    /// it has gone stale.
    public var scrobbleRevision: Int {
        scrobbleRevisionCounter.value
    }

    /// Identity of every stored scrobble (`timestamp NUL lowercased title`),
    /// read as two columns instead of decoding whole records.
    public func scrobbleIdentities() throws -> Set<String> {
        try dbQueue.read { db in
            var identities = Set<String>()
            let rows = try Row.fetchCursor(db, sql: "SELECT timestamp, trackTitle FROM scrobbles")
            while let row = try rows.next() {
                let timestamp: Date = row["timestamp"]
                let title: String = row["trackTitle"]
                identities.insert(Self.scrobbleIdentity(timestamp: timestamp, title: title))
            }
            return identities
        }
    }

    public static func scrobbleIdentity(timestamp: Date, title: String) -> String {
        "\(Int(timestamp.timeIntervalSince1970))\u{0}\(title.lowercased())"
    }

    public func fetchPendingScrobbles() throws -> [ScrobbleRecord] {
        try dbQueue.read { db in
            try ScrobbleRecord
                .filter(Column("submitted") == false)
                .order(Column("timestamp").asc)
                .fetchAll(db)
        }
    }

    /// Retires pending scrobbles older than the cutoff by marking them submitted,
    /// keeping them as local listening history without queuing them for Last.fm,
    /// which rejects scrobbles more than 14 days old. Pass `.distantFuture` to
    /// retire the entire pending queue.
    public func retirePendingScrobbles(olderThan cutoff: Date) throws {
        _ = try dbQueue.write { db in
            try ScrobbleRecord
                .filter(Column("submitted") == false && Column("timestamp") < cutoff)
                .updateAll(db, Column("submitted").set(to: true))
        }
    }

    public func markScrobblesSubmitted(ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        _ = try dbQueue.write { db in
            try ScrobbleRecord
                .filter(ids.contains(Column("id")))
                .updateAll(db, Column("submitted").set(to: true))
        }
    }

    /// Clears every track's analyzed flag and the per-directory verdicts that
    /// remember the batches were already identified, so a re-analysis is a real
    /// re-analysis rather than a queue that finds nothing due.
    public func resetAllAIAnalyzed() throws {
        try dbQueue.write { db in
            _ = try TrackRecord
                .updateAll(db, Column("aiAnalyzed").set(to: false))
            try db.execute(
                sql: "DELETE FROM enrichmentState WHERE scope = ?",
                arguments: [EnrichmentScope.aiBatch.rawValue]
            )
        }
    }

    /// Backfills each track's play count and last-played time from the scrobble
    /// history (which includes imported Last.fm plays), so the Plays column and
    /// every play-based sort reflect a freshly imported history rather than only
    /// local playback.
    public func reconcilePlayCountsFromScrobbles() throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE tracks SET
                    playCount = totals.plays,
                    lastPlayed = totals.last
                FROM (
                    SELECT trackTitle, artist, COUNT(*) AS plays, MAX(timestamp) AS last
                    FROM scrobbles
                    GROUP BY trackTitle, artist
                ) AS totals
                WHERE totals.trackTitle = tracks.title AND totals.artist = tracks.artist
            """)
        }
    }

    public func incrementPlayCount(trackId: Int64) throws {
        try dbQueue.write { db in
            if var track = try TrackRecord.fetchOne(db, id: trackId) {
                track.playCount += 1
                track.lastPlayed = Date()
                try track.update(db)
            }
        }
    }
}
