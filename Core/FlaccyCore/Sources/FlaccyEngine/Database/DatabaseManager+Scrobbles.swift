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

    /// The stored plays from `since` on, as the dedup ledger reads them: two
    /// narrow columns and the keys, with no record decoded.
    public func storedListens(since: Date) throws -> [ListenHistory.StoredListen] {
        try dbQueue.read { db in
            var listens: [ListenHistory.StoredListen] = []
            let rows = try Row.fetchCursor(db, sql: """
                SELECT CAST(strftime('%s', timestamp) AS INTEGER) AS ts, titleKey, artistKey, duration > 0 AS playedHere
                FROM scrobbles WHERE timestamp >= ?
            """, arguments: [since])
            while let row = try rows.next() {
                listens.append(ListenHistory.StoredListen(
                    timestamp: row["ts"], titleKey: row["titleKey"], artistKey: row["artistKey"], playedHere: row["playedHere"]
                ))
            }
            return listens
        }
    }

    /// One scrobble pulled from Last.fm.
    public struct PulledListen: Sendable {
        public let title: String
        public let artist: String
        public let album: String
        public let timestamp: Date

        public init(title: String, artist: String, album: String, timestamp: Date) {
            self.title = title
            self.artist = artist
            self.album = album
            self.timestamp = timestamp
        }
    }

    /// Stores scrobbles pulled from Last.fm, already deduplicated by the
    /// caller's ledger, in one transaction as submitted plays of unknown
    /// length. Each insert also skips a play already stored at the same second
    /// under the same title key, so overlapping syncs can never store a page
    /// twice. Returns how many were stored.
    @discardableResult
    public func insertPulledListens(_ listens: [PulledListen]) throws -> Int {
        guard !listens.isEmpty else { return 0 }
        let stored = try dbQueue.write { db -> Int in
            let insert = try db.cachedStatement(sql: """
                INSERT INTO scrobbles
                    (trackTitle, artist, albumTitle, timestamp, duration, submitted, titleKey, artistKey, albumKey)
                SELECT ?1, ?2, ?3, ?4, 0, 1, ?5, ?6, ?7
                WHERE NOT EXISTS (SELECT 1 FROM scrobbles WHERE timestamp = ?4 AND titleKey = ?5)
            """)
            var memo = ListenKeyMemo()
            var stored = 0
            for listen in listens {
                let keys = memo.keys(title: listen.title, artist: listen.artist, album: listen.album)
                try insert.execute(arguments: [
                    listen.title, listen.artist, listen.album, listen.timestamp, keys.title, keys.artist, keys.album,
                ])
                stored += db.changesCount
            }
            return stored
        }
        if stored > 0 {
            scrobbleRevisionCounter.bump()
        }
        return stored
    }

    /// The newest play that came from Last.fm rather than from this device.
    public func newestPulledListen() throws -> Date? {
        try dbQueue.read { db in
            try Date.fetchOne(db, sql: "SELECT MAX(timestamp) FROM scrobbles WHERE duration = 0")
        }
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

    /// Rewrites each library song's play count and last-played time from the
    /// whole history, matched by listen key so a "feat." credit, a remaster
    /// tag or different casing counts toward the song the library holds. Only
    /// rows whose numbers change are written, in one transaction; songs a
    /// server supplies keep the counts that server keeps. Returns how many
    /// rows changed.
    @discardableResult
    public func reconcilePlayCountsFromScrobbles() throws -> Int {
        try dbQueue.write { db in
            let tallies = try Self.listenTallies(db)
            guard !tallies.isEmpty else { return 0 }
            let tracks = try Row.fetchAll(db, sql: """
                SELECT id, title, artist, playCount, lastPlayed FROM tracks WHERE remoteServer IS NULL
            """)
            let update = try db.cachedStatement(sql: "UPDATE tracks SET playCount = ?, lastPlayed = ? WHERE id = ?")
            var changed = 0
            for track in tracks {
                let id: Int64 = track["id"]
                let title: String = track["title"]
                let artist: String = track["artist"]
                let playCount: Int = track["playCount"]
                let lastPlayed: Date? = track["lastPlayed"]
                guard let tally = tallies[ListenHistory.trackKey(title: title, artist: artist)] else { continue }
                if tally.plays == playCount, lastPlayed == tally.latest { continue }
                try update.execute(arguments: [tally.plays, tally.latest, id])
                changed += 1
            }
            return changed
        }
    }

    private struct ListenTally {
        let plays: Int
        let latest: Date
    }

    /// Plays and latest play per song across the whole history, keyed like
    /// `ListenHistory.trackKey`. The database groups on the key columns, so
    /// the cost is the number of distinct songs, not of plays.
    private static func listenTallies(_ db: Database) throws -> [String: ListenTally] {
        var tallies: [String: ListenTally] = [:]
        let rows = try Row.fetchCursor(db, sql: """
            SELECT titleKey, artistKey, COUNT(*) AS plays, MAX(timestamp) AS latest FROM scrobbles
            GROUP BY titleKey, artistKey
        """)
        while let row = try rows.next() {
            let title: String = row["titleKey"]
            let artist: String = row["artistKey"]
            tallies[title + "\u{0}" + artist] = ListenTally(plays: row["plays"], latest: row["latest"])
        }
        return tallies
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
