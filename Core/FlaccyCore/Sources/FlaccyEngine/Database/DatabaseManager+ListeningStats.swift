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

    /// Every play as the mixes count it: its `ListenHistory.trackKey`, the
    /// artist as credited and when it played. A row stored before plays kept
    /// their keys is folded here instead.
    public func fetchListens() throws -> [(key: String, artist: String, timestamp: Date)] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT titleKey, artistKey, trackTitle, artist, timestamp FROM scrobbles")
            return rows.map { row in
                let titleKey: String = row["titleKey"]
                let artistKey: String = row["artistKey"]
                let artist: String = row["artist"]
                let key = titleKey.isEmpty || artistKey.isEmpty
                    ? ListenHistory.trackKey(title: row["trackTitle"], artist: artist)
                    : Self.trackKey(titleKey: titleKey, artistKey: artistKey)
                return (key: key, artist: artist, timestamp: row["timestamp"])
            }
        }
    }

    /// Plays per song across the whole history, most played first, keyed by
    /// `ListenHistory.trackKey` so a library track is matched with
    /// `ListenHistory.trackKey(title:artist:)`.
    public func playCountByTrack() throws -> [(key: String, count: Int)] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT titleKey, artistKey, COUNT(*) AS c FROM scrobbles
                GROUP BY titleKey, artistKey
                ORDER BY c DESC
            """)
            return rows.map { (key: Self.trackKey(titleKey: $0["titleKey"], artistKey: $0["artistKey"]), count: $0["c"]) }
        }
    }

    private static func trackKey(titleKey: String, artistKey: String) -> String {
        titleKey + "\u{0}" + artistKey
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

    /// What a play of unknown length counts for when the library holds no song
    /// it matches: a typical song.
    public static let unknownPlaySeconds = 210

    /// Play count and total listened seconds for a window, in aggregates that
    /// decode no rows. A play pulled from Last.fm has no recorded length, so it
    /// counts as the length of the library song its listen key matches in
    /// `libraryLengths` (keyed by `ListenHistory.trackKey`), or a typical song.
    public func scrobbleTotals(
        from: Date, to: Date, libraryLengths: [String: Int] = [:]
    ) throws -> (plays: Int, seconds: Int) {
        try dbQueue.read { db in
            let window = Self.scrobbleWindow(from: from, to: to)
            let row = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS plays, COALESCE(SUM(duration), 0) AS seconds FROM scrobbles \(window.clause)
            """, arguments: window.arguments)
            let unrecorded = try Self.unrecordedLengths(db, window: window)
            let estimated = unrecorded.reduce(0) { total, group in
                total + group.plays * (libraryLengths[group.trackKey] ?? Self.unknownPlaySeconds)
            }
            return (plays: row?["plays"] ?? 0, seconds: (row?["seconds"] ?? 0) + estimated)
        }
    }

    private struct UnrecordedGroup {
        let trackKey: String
        let artistKey: String
        let artist: String
        let plays: Int
    }

    /// The window's plays with no recorded length, counted per song and artist
    /// spelling, so a caller can price each song at its library length.
    private static func unrecordedLengths(
        _ db: Database, window: (clause: String, arguments: StatementArguments)
    ) throws -> [UnrecordedGroup] {
        let filter = joinedClause(window.clause, "duration = 0")
        let rows = try Row.fetchAll(db, sql: """
            SELECT titleKey, artistKey, artist, COUNT(*) AS c FROM scrobbles \(filter)
            GROUP BY titleKey, artistKey, artist
        """, arguments: window.arguments)
        return rows.map {
            UnrecordedGroup(
                trackKey: trackKey(titleKey: $0["titleKey"], artistKey: $0["artistKey"]),
                artistKey: $0["artistKey"], artist: $0["artist"], plays: $0["c"]
            )
        }
    }

    /// Plays and listened seconds per artist for a window, one entry per
    /// artist key named by the spelling heard most. Plays with no recorded
    /// length count as in `scrobbleTotals`. The result is as long as the
    /// number of distinct artists, which is small next to the scrobble table,
    /// and its sums are the window's totals.
    public func scrobbleArtistCounts(
        from: Date, to: Date, libraryLengths: [String: Int] = [:]
    ) throws -> [(artist: String, count: Int, seconds: Int)] {
        var spellings = try groupedSpellings(from: from, to: to, keyColumns: "artistKey", nameColumns: "artist", seconds: true)
        let unrecorded = try dbQueue.read { db in
            try Self.unrecordedLengths(db, window: Self.scrobbleWindow(from: from, to: to))
        }
        for group in unrecorded {
            spellings.append(ListenHistory.Spelling(
                key: group.artistKey, name: group.artist, plays: 0,
                seconds: group.plays * (libraryLengths[group.trackKey] ?? Self.unknownPlaySeconds), latest: 0
            ))
        }
        return ListenHistory.foldSpellings(spellings).map { (artist: $0.name, count: $0.plays, seconds: $0.seconds) }
    }

    public func scrobbleTopAlbums(from: Date, to: Date, limit: Int) throws -> [(album: String, artist: String, count: Int)] {
        let spellings = try groupedSpellings(
            from: from, to: to, keyColumns: "albumKey, artistKey", nameColumns: "albumTitle, artist",
            extraClause: "albumKey <> ''"
        )
        return ListenHistory.foldSpellings(spellings).prefix(limit).map { folded in
            let parts = Self.splitName(folded.name)
            return (album: parts.first, artist: parts.second, count: folded.plays)
        }
    }

    public func scrobbleTopTracks(from: Date, to: Date, limit: Int) throws -> [(title: String, artist: String, count: Int)] {
        let spellings = try groupedSpellings(
            from: from, to: to, keyColumns: "titleKey, artistKey", nameColumns: "trackTitle, artist"
        )
        return ListenHistory.foldSpellings(spellings).prefix(limit).map { folded in
            let parts = Self.splitName(folded.name)
            return (title: parts.first, artist: parts.second, count: folded.plays)
        }
    }

    /// Plays per song for a window, one row per `ListenHistory.trackKey`.
    public func scrobbleTrackCounts(from: Date, to: Date) throws -> [(key: String, count: Int)] {
        try dbQueue.read { db in
            let window = Self.scrobbleWindow(from: from, to: to)
            let rows = try Row.fetchAll(db, sql: """
                SELECT titleKey, artistKey, COUNT(*) AS c FROM scrobbles \(window.clause)
                GROUP BY titleKey, artistKey
            """, arguments: window.arguments)
            return rows.map { (key: Self.trackKey(titleKey: $0["titleKey"], artistKey: $0["artistKey"]), count: $0["c"]) }
        }
    }

    /// The length in seconds of each song in the library folder, keyed by
    /// `ListenHistory.trackKey` (the first of several versions wins). Remote
    /// songs are left out: a server keeps its own counts.
    public func libraryPlayLengths() throws -> [String: Int] {
        try dbQueue.read { db in
            var lengths: [String: Int] = [:]
            var memo = ListenKeyMemo()
            let rows = try Row.fetchCursor(db, sql: """
                SELECT title, artist, duration FROM tracks WHERE remoteServer IS NULL AND duration > 0 ORDER BY id
            """)
            while let row = try rows.next() {
                let title: String = row["title"]
                let artist: String = row["artist"]
                let duration: Double = row["duration"]
                let keys = memo.keys(title: title, artist: artist, album: "")
                let key = Self.trackKey(titleKey: keys.title, artistKey: keys.artist)
                if lengths[key] == nil { lengths[key] = Int(duration.rounded()) }
            }
            return lengths
        }
    }

    /// A cheap fingerprint of what `libraryPlayLengths` reads, so a caller can
    /// tell in one aggregate whether its copy has gone stale.
    public func libraryPlayLengthsStamp() throws -> String {
        try dbQueue.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS n, COALESCE(SUM(duration), 0) AS d, COALESCE(SUM(LENGTH(title) + LENGTH(artist)), 0) AS t
                FROM tracks WHERE remoteServer IS NULL
            """)
            return "\(row?["n"] ?? 0)/\(row?["d"] ?? 0.0)/\(row?["t"] ?? 0)"
        }
    }

    /// How many times a release was played: plays of its songs that were
    /// scrobbled from this release or from no release at all. A song listed
    /// twice counts once.
    public func albumListenCount(albumTitle: String, songs: [(title: String, artist: String)]) throws -> Int {
        let albumKey = ListenHistory.albumKey(albumTitle)
        var seen = Set<String>()
        let songKeys = songs.compactMap { song -> (title: String, artist: String)? in
            let title = ListenHistory.titleKey(song.title)
            let artist = ListenHistory.artistKey(song.artist)
            guard seen.insert(Self.trackKey(titleKey: title, artistKey: artist)).inserted else { return nil }
            return (title: title, artist: artist)
        }
        return try dbQueue.read { db in
            let count = try db.cachedStatement(sql: """
                SELECT COUNT(*) FROM scrobbles
                WHERE titleKey = ? AND artistKey = ? AND (albumKey = ? OR albumKey = '')
            """)
            var total = 0
            for song in songKeys {
                total += try Int.fetchOne(count, arguments: [song.title, song.artist, albumKey]) ?? 0
            }
            return total
        }
    }

    /// The window's plays grouped by a key and the spelling heard under it,
    /// ready for `ListenHistory.foldSpellings`. A multi-column name is joined
    /// with the unit separator so the fold can carry an album and its artist together.
    private func groupedSpellings(
        from: Date, to: Date, keyColumns: String, nameColumns: String, seconds: Bool = false, extraClause: String? = nil
    ) throws -> [ListenHistory.Spelling<String>] {
        try dbQueue.read { db in
            let window = Self.scrobbleWindow(from: from, to: to)
            let filter = Self.joinedClause(window.clause, extraClause)
            let rows = try Row.fetchAll(db, sql: """
                SELECT \(Self.joined(keyColumns)) AS k, \(Self.joined(nameColumns)) AS n, COUNT(*) AS c,
                       \(seconds ? "COALESCE(SUM(duration), 0)" : "0") AS s,
                       CAST(strftime('%s', MAX(timestamp)) AS INTEGER) AS latest
                FROM scrobbles \(filter)
                GROUP BY \(keyColumns), \(nameColumns)
            """, arguments: window.arguments)
            return rows.map {
                ListenHistory.Spelling(key: $0["k"], name: $0["n"], plays: $0["c"], seconds: $0["s"], latest: $0["latest"])
            }
        }
    }

    private static func joined(_ columns: String) -> String {
        columns.components(separatedBy: ", ").joined(separator: " || char(31) || ")
    }

    private static func joinedClause(_ clause: String, _ extra: String?) -> String {
        guard let extra else { return clause }
        return clause.isEmpty ? "WHERE \(extra)" : "\(clause) AND \(extra)"
    }

    private static func splitName(_ name: String) -> (first: String, second: String) {
        let parts = name.split(separator: "\u{1F}", maxSplits: 1, omittingEmptySubsequences: false)
        return (first: String(parts[0]), second: parts.count > 1 ? String(parts[1]) : "")
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
