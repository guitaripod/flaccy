import Foundation
import MidgarCore
import FlaccyCore
import GRDB

extension DatabaseManager {

    func fetchScrobbleTimestamps(since: Date) throws -> [Date] {
        try dbQueue.read { db in
            try Date.fetchAll(db, sql: "SELECT timestamp FROM scrobbles WHERE timestamp >= ? ORDER BY timestamp ASC", arguments: [since])
        }
    }

    public func fetchScrobbleRows(from: Date, to: Date) throws -> [ScrobbleRecord] {
        try dbQueue.read { db in
            try ScrobbleRecord
                .filter(Column("timestamp") >= from && Column("timestamp") < to)
                .order(Column("timestamp").asc)
                .fetchAll(db)
        }
    }

    public func scrobbleYears() throws -> [Int] {
        try dbQueue.read { db in
            try Int.fetchAll(
                db,
                sql: "SELECT DISTINCT CAST(strftime('%Y', timestamp) AS INTEGER) FROM scrobbles WHERE timestamp >= ? ORDER BY 1 DESC",
                arguments: [Self.firstDatedScrobble]
            )
        }
    }

    public func fetchAllScrobbleRows() throws -> [ScrobbleRecord] {
        try dbQueue.read { db in
            try ScrobbleRecord.order(Column("timestamp").asc).fetchAll(db)
        }
    }

    public func playCountByTrack() throws -> [(trackTitle: String, artist: String, count: Int)] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT trackTitle, artist, COUNT(*) AS c FROM scrobbles
                GROUP BY trackTitle, artist
                ORDER BY c DESC
            """)
            return rows.map { (trackTitle: $0["trackTitle"], artist: $0["artist"], count: $0["c"]) }
        }
    }

    public func lastPlayedByAlbum() throws -> [(albumTitle: String, artist: String, lastPlayed: Date, playCount: Int)] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT albumTitle, artist, MAX(timestamp) AS last, COUNT(*) AS c FROM scrobbles
                GROUP BY albumTitle, artist
            """)
            return rows.map { (albumTitle: $0["albumTitle"], artist: $0["artist"], lastPlayed: $0["last"], playCount: $0["c"]) }
        }
    }

    public func scrobbleCountInRange(from: Date, to: Date) throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM scrobbles WHERE timestamp >= ? AND timestamp < ?", arguments: [from, to]) ?? 0
        }
    }

    /// Play count and total listened seconds for a window, in one aggregate
    /// that decodes no rows.
    public func scrobbleTotals(from: Date, to: Date) throws -> (plays: Int, seconds: Int) {
        try dbQueue.read { db in
            let window = Self.scrobbleWindow(from: from, to: to)
            let row = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS plays, COALESCE(SUM(duration), 0) AS seconds FROM scrobbles \(window.clause)
            """, arguments: window.arguments)
            return (plays: row?["plays"] ?? 0, seconds: row?["seconds"] ?? 0)
        }
    }

    /// Plays and listened seconds per artist name for a window. The result is
    /// as long as the number of distinct artists, which is small next to the
    /// scrobble table, and its sums are the window's totals.
    public func scrobbleArtistCounts(from: Date, to: Date) throws -> [(artist: String, count: Int, seconds: Int)] {
        try dbQueue.read { db in
            let window = Self.scrobbleWindow(from: from, to: to)
            let rows = try Row.fetchAll(db, sql: """
                SELECT artist, COUNT(*) AS c, COALESCE(SUM(duration), 0) AS s FROM scrobbles \(window.clause)
                GROUP BY artist
            """, arguments: window.arguments)
            return rows.map { (artist: $0["artist"], count: $0["c"], seconds: $0["s"]) }
        }
    }

    public func scrobbleTopAlbums(from: Date, to: Date, limit: Int) throws -> [(album: String, artist: String, count: Int)] {
        try dbQueue.read { db in
            let window = Self.scrobbleWindow(from: from, to: to)
            let rows = try Row.fetchAll(db, sql: """
                SELECT albumTitle, artist, COUNT(*) AS c FROM scrobbles \(window.clause)
                GROUP BY albumTitle, artist
                ORDER BY c DESC, albumTitle ASC, artist ASC
                LIMIT \(limit)
            """, arguments: window.arguments)
            return rows.map { (album: $0["albumTitle"], artist: $0["artist"], count: $0["c"]) }
        }
    }

    public func scrobbleTopTracks(from: Date, to: Date, limit: Int) throws -> [(title: String, artist: String, count: Int)] {
        try dbQueue.read { db in
            let window = Self.scrobbleWindow(from: from, to: to)
            let rows = try Row.fetchAll(db, sql: """
                SELECT trackTitle, artist, COUNT(*) AS c FROM scrobbles \(window.clause)
                GROUP BY trackTitle, artist
                ORDER BY c DESC, trackTitle ASC, artist ASC
                LIMIT \(limit)
            """, arguments: window.arguments)
            return rows.map { (title: $0["trackTitle"], artist: $0["artist"], count: $0["c"]) }
        }
    }

    /// Plays per track for a window, one row per distinct title and artist.
    public func scrobbleTrackCounts(from: Date, to: Date) throws -> [(title: String, artist: String, count: Int)] {
        try dbQueue.read { db in
            let window = Self.scrobbleWindow(from: from, to: to)
            let rows = try Row.fetchAll(db, sql: """
                SELECT trackTitle, artist, COUNT(*) AS c FROM scrobbles \(window.clause)
                GROUP BY trackTitle, artist
            """, arguments: window.arguments)
            return rows.map { (title: $0["trackTitle"], artist: $0["artist"], count: $0["c"]) }
        }
    }

    /// Plays grouped into quarter-hour buckets of Unix time (`seconds / 900`).
    /// Every UTC offset in use is a multiple of fifteen minutes, so a bucket
    /// never straddles a local hour or day and the clock, the heatmap and the
    /// streak can all be derived from this one narrow result.
    public func scrobbleQuarterHourCounts(from: Date, to: Date) throws -> [(bucket: Int, count: Int)] {
        try dbQueue.read { db in
            let window = Self.scrobbleWindow(from: from, to: to)
            let rows = try Row.fetchAll(db, sql: """
                SELECT CAST(strftime('%s', timestamp) AS INTEGER) / 900 AS b, COUNT(*) AS c FROM scrobbles \(window.clause)
                GROUP BY b
            """, arguments: window.arguments)
            return rows.map { (bucket: $0["b"], count: $0["c"]) }
        }
    }

    /// The `WHERE` for a half-open time window, or nothing at all when the
    /// window is the whole table: a bounded clause sends SQLite through the
    /// timestamp index and back to the table for every row, which is slower
    /// than reading the table straight through when every row qualifies.
    private static func scrobbleWindow(from: Date, to: Date) -> (clause: String, arguments: StatementArguments) {
        if from == .distantPast, to == .distantFuture { return ("", StatementArguments()) }
        return ("WHERE timestamp >= ? AND timestamp < ?", [from, to])
    }

    /// The paywall's proof of what the library holds, read in one statement
    /// that touches no BLOB column. The codec predicate is `Track.isLossless`
    /// rewritten as SQL over the same `Track.losslessCodecs`.
    public func libraryTotals() throws -> (tracks: Int, lossless: Int, seconds: Double) {
        let codecs = Track.losslessCodecs.sorted()
        let placeholders = codecs.map { _ in "?" }.joined(separator: ", ")
        return try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS tracks,
                       COALESCE(SUM(CASE WHEN UPPER(codec) IN (\(placeholders)) THEN 1 ELSE 0 END), 0) AS lossless,
                       COALESCE(SUM(duration), 0) AS seconds
                FROM tracks
                """, arguments: StatementArguments(codecs)) else {
                return (tracks: 0, lossless: 0, seconds: 0)
            }
            return (tracks: row["tracks"], lossless: row["lossless"], seconds: row["seconds"])
        }
    }

    public func scrobbleCount(submittedOnly: Bool) throws -> Int {
        try dbQueue.read { db in
            let scrobbles = submittedOnly ? ScrobbleRecord.filter(Column("submitted") == true) : ScrobbleRecord.all()
            return try scrobbles.fetchCount(db)
        }
    }

    public func lyricsMatchedCount() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM lyrics WHERE syncedLyrics IS NOT NULL") ?? 0
        }
    }

    /// Covers the library can still show: nothing deletes an `albumInfo` row
    /// when its last track goes, so a found cover counts only while an album
    /// with that title and artist still exists in `tracks`.
    public func coversResolvedCount() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM albumInfo
                WHERE coverArtURL IS NOT NULL
                  AND EXISTS (
                      SELECT 1 FROM tracks t
                      WHERE t.albumTitle = albumInfo.title AND t.artist = albumInfo.artist
                  )
                """) ?? 0
        }
    }

    public func aiReviewedTrackCount() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks WHERE aiAnalyzed = 1") ?? 0
        }
    }

    public func fetchLibraryArtists() throws -> Set<String> {
        try dbQueue.read { db in
            Set(try String.fetchAll(db, sql: "SELECT DISTINCT artist FROM tracks"))
        }
    }
}
