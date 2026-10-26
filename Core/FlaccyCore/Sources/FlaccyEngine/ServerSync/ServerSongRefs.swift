import FlaccyCore
import Foundation
import GRDB

/// Builds the `SongRef` a mutation carries, and keeps the index that maps song keys to library tracks.
enum SyncSongRefs {

    /// A reference known only by what a play recorded.
    static func ref(title: String, artist: String, album: String) throws -> ServerSongRef {
        let key = try ServerCoreBridge.songKey(
            artistKey: ListenHistory.artistKey(artist), titleKey: ListenHistory.titleKey(title)
        )
        let albumKey = ListenHistory.albumKey(album)
        return ServerSongRef(
            songKey: key, title: title, artist: artist, album: album,
            albumKey: albumKey.isEmpty ? nil : albumKey
        )
    }

    static func songKey(title: String, artist: String) throws -> String {
        try ServerCoreBridge.songKey(
            artistKey: ListenHistory.artistKey(artist), titleKey: ListenHistory.titleKey(title)
        )
    }

    /// The reference for a library track, by its `fileURL`. A server's song carries no path, because a path names one library.
    static func ref(_ db: Database, fileURL: String) throws -> ServerSongRef? {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT title, artist, albumTitle, duration, audioFingerprint, musicBrainzID FROM tracks WHERE fileURL = ?",
            arguments: [fileURL]
        ) else { return nil }
        var song = try ref(title: row["title"], artist: row["artist"], album: row["albumTitle"])
        let duration: Double = row["duration"]
        song.durationMs = Int64((duration * 1000).rounded())
        song.fp = (row["audioFingerprint"] as String?).flatMap { $0.isEmpty ? nil : $0 }
        song.mbid = (row["musicBrainzID"] as String?).flatMap { $0.isEmpty ? nil : $0 }
        song.relPath = RemoteTrackPath.isRemote(fileURL) ? nil : fileURL
        return song
    }

    /// Brings `sync_song_keys` level with `tracks`, computing keys only for rows that are new or retitled, a chunk at a time.
    static func refreshIndex(_ database: DatabaseManager) throws {
        try database.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM sync_song_keys WHERE trackId NOT IN (SELECT id FROM tracks)")
        }
        while try refreshChunk(database) == chunkSize {}
    }

    private static let chunkSize = 2_000

    private static func refreshChunk(_ database: DatabaseManager) throws -> Int {
        try database.dbQueue.write { db in
            let stale = try Row.fetchAll(
                db,
                sql: """
                    SELECT t.id, t.title, t.artist FROM tracks t
                    LEFT JOIN sync_song_keys k ON k.trackId = t.id
                    WHERE k.trackId IS NULL OR k.title <> t.title OR k.artist <> t.artist
                    LIMIT ?
                    """,
                arguments: [chunkSize]
            )
            var memo = ListenKeyMemo()
            let pairs = stale.map { row -> (artistKey: String, titleKey: String) in
                let keys = memo.keys(title: row["title"], artist: row["artist"], album: "")
                return (keys.artist, keys.title)
            }
            let songKeys = try ServerCoreBridge.songKeys(pairs)
            for (row, key) in zip(stale, songKeys) {
                try db.execute(
                    sql: """
                        INSERT INTO sync_song_keys (trackId, title, artist, songKey) VALUES (?, ?, ?, ?)
                        ON CONFLICT(trackId) DO UPDATE SET
                            title = excluded.title, artist = excluded.artist, songKey = excluded.songKey
                        """,
                    arguments: [row["id"] as Int64, row["title"] as String, row["artist"] as String, key]
                )
            }
            return stale.count
        }
    }
}

/// Finds the local track a reference names.
struct SyncSongResolver {

    private struct Candidate {
        var path: String
        var album: String
        var durationMs: Int64
        var lossless: Bool
    }

    private static let durationToleranceMs: Int64 = 2_000

    let db: Database

    /// True when `fileURL` is a track of `songKey`: the check that keeps an entry on the file the person chose.
    func pathHasSongKey(_ fileURL: String, _ songKey: String) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: """
                SELECT EXISTS (
                    SELECT 1 FROM sync_song_keys k JOIN tracks t ON t.id = k.trackId
                    WHERE t.fileURL = ? AND k.songKey = ?
                )
                """,
            arguments: [fileURL, songKey]
        ) ?? false
    }

    /// The `fileURL` of the track `song` names, by the ladder: fingerprint, MusicBrainz id, song key with album and duration, song key alone, relative path.
    func resolve(_ song: ServerSongRef) throws -> String? {
        if let fp = song.fp, !fp.isEmpty,
           let found = best(try byColumn("audioFingerprint", fp), song) { return found }
        if let mbid = song.mbid, !mbid.isEmpty,
           let found = best(try byColumn("musicBrainzID", mbid), song) { return found }
        let bySongKey = try bySongKey(song.songKey)
        if let found = exactEdition(bySongKey, song) { return found }
        if let found = best(bySongKey, song) { return found }
        return try byPath(song.relPath)
    }

    private func byColumn(_ column: String, _ value: String) throws -> [Candidate] {
        try candidates(sql: "SELECT fileURL, albumTitle, duration, codec FROM tracks WHERE \(column) = ?", value)
    }

    private func bySongKey(_ songKey: String) throws -> [Candidate] {
        try candidates(
            sql: """
                SELECT t.fileURL, t.albumTitle, t.duration, t.codec FROM sync_song_keys k
                JOIN tracks t ON t.id = k.trackId WHERE k.songKey = ?
                """,
            songKey
        )
    }

    private func candidates(sql: String, _ value: String) throws -> [Candidate] {
        try Row.fetchAll(db, sql: sql, arguments: [value]).map { row in
            let codec: String? = row["codec"]
            let duration: Double = row["duration"]
            return Candidate(
                path: row["fileURL"], album: row["albumTitle"], durationMs: Int64((duration * 1000).rounded()),
                lossless: codec.map { Track.losslessCodecs.contains($0.uppercased()) } ?? false
            )
        }
    }

    private func exactEdition(_ candidates: [Candidate], _ song: ServerSongRef) -> String? {
        guard let albumKey = song.albumKey else { return nil }
        let matching = candidates.filter {
            ListenHistory.albumKey($0.album) == albumKey
                && abs($0.durationMs - song.durationMs) <= Self.durationToleranceMs
        }
        return Self.rank(matching, song)?.path
    }

    private func best(_ candidates: [Candidate], _ song: ServerSongRef) -> String? {
        Self.rank(candidates, song)?.path
    }

    private func byPath(_ relPath: String?) throws -> String? {
        guard let path = relPath, !path.isEmpty else { return nil }
        return try String.fetchOne(db, sql: "SELECT fileURL FROM tracks WHERE fileURL = ?", arguments: [path])
    }

    /// Same album first, lossless over lossy, a local file over a server's, then the lowest path.
    private static func rank(_ candidates: [Candidate], _ song: ServerSongRef) -> Candidate? {
        let wanted = song.albumKey ?? ListenHistory.albumKey(song.album)
        func order(_ candidate: Candidate) -> [Int] {
            [
                ListenHistory.albumKey(candidate.album) == wanted ? 0 : 1,
                candidate.lossless ? 0 : 1,
                RemoteTrackPath.isRemote(candidate.path) ? 1 : 0,
            ]
        }
        return candidates.min { a, b in
            let left = order(a)
            let right = order(b)
            if left != right { return left.lexicographicallyPrecedes(right) }
            return a.path < b.path
        }
    }
}
