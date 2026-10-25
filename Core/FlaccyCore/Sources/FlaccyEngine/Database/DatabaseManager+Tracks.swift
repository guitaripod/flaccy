import Foundation
import MidgarCore
import FlaccyCore
import GRDB

extension DatabaseManager {

    @discardableResult
    public func insertTrack(_ track: TrackRecord) throws -> TrackRecord {
        try dbQueue.write { db in
            try track.insertAndFetch(db, as: TrackRecord.self)
        }
    }

    func updateTrack(_ track: TrackRecord) throws {
        try dbQueue.write { db in
            try track.update(db)
        }
    }

    /// Updates a track fetched without its artwork BLOB, leaving the stored
    /// `artworkData` column untouched.
    public func updateTrackPreservingArtwork(_ track: TrackRecord) throws {
        try dbQueue.write { db in
            try track.update(db, columns: Self.trackColumnsWithoutArtwork)
        }
    }

    /// Inserts each row independently inside the batch transaction so one
    /// conflicting row (e.g. a duplicate fileURL from a concurrent import)
    /// never rolls back the other tracks in the batch. Embedded artwork is
    /// hoisted into `albumInfo` once per album rather than duplicated on every
    /// track row, which is what lets the enrichment queue see that an album
    /// already has a cover and skip it.
    public func insertTracks(_ tracks: [TrackRecord]) throws {
        guard !tracks.isEmpty else { return }
        try dbQueue.write { db in
            for track in tracks {
                do {
                    try Self.hoistingCoverArt(track, in: db).insert(db)
                } catch {
                    MidgarLog.error("Skipped track insert for \(track.fileURL): \(error.localizedDescription)", category: .database)
                }
            }
        }
    }

    /// Moves a track's embedded artwork to its album and returns the row to
    /// store. A track with no album title keeps its own artwork, since there is
    /// no album row that could hold it — the same rule migration v10 applies.
    private static func hoistingCoverArt(_ track: TrackRecord, in db: Database) throws -> TrackRecord {
        guard !track.albumTitle.isEmpty, let artwork = track.artworkData else { return track }
        try saveAlbumCoverArtIfMissing(title: track.albumTitle, artist: track.artist, data: artwork, in: db)
        var stripped = track
        stripped.artworkData = nil
        return stripped
    }

    /// Fetches every track without the artwork BLOB column so full-library reads stay lean;
    /// `artworkData` decodes as nil. Use `fetchAlbumArtwork(title:artist:)` for images.
    public func fetchAllTracks() throws -> [TrackRecord] {
        try dbQueue.read { db in
            try TrackRecord.fetchAll(db, TrackRecord.select(Self.trackColumnsWithoutArtwork))
        }
    }

    private static let trackColumnsWithoutArtwork: [Column] = [
        Column("id"), Column("fileURL"), Column("title"), Column("artist"),
        Column("albumTitle"), Column("albumArtist"), Column("trackNumber"), Column("duration"),
        Column("lastFMArtworkURL"), Column("musicBrainzID"), Column("albumMusicBrainzID"),
        Column("dateAdded"), Column("lastPlayed"), Column("playCount"),
        Column("aiAnalyzed"), Column("analysisAttemptedAt"),
        Column("codec"), Column("bitDepth"), Column("sampleRate"), Column("channels"),
        Column("loved"), Column("lovedPendingOp"),
    ]

    public func fetchAllTrackRelativePaths() throws -> Set<String> {
        try dbQueue.read { db in
            let paths = try String.fetchAll(db, sql: "SELECT fileURL FROM tracks")
            return Set(paths)
        }
    }

    public func fetchTrackSortKeys() throws -> [(fileURL: String, lastPlayed: Date?)] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT fileURL, lastPlayed FROM tracks")
            return rows.map { (fileURL: $0["fileURL"], lastPlayed: $0["lastPlayed"]) }
        }
    }

    /// Every track's relative path with the date it entered the library.
    public func fetchTrackDateAddedByPath() throws -> [(path: String, dateAdded: Date)] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT fileURL, dateAdded FROM tracks")
            return rows.map { (path: $0["fileURL"], dateAdded: $0["dateAdded"]) }
        }
    }

    public func fetchTrack(byRelativePath path: String) throws -> TrackRecord? {
        try dbQueue.read { db in
            try TrackRecord.filter(Column("fileURL") == path).fetchOne(db)
        }
    }

    public func deleteTrack(id: Int64) throws {
        try dbQueue.write { db in
            if let fileURL = try String.fetchOne(db, sql: "SELECT fileURL FROM tracks WHERE id = ?", arguments: [id]) {
                _ = try PlaylistTrackRecord.filter(Column("trackFileURL") == fileURL).deleteAll(db)
            }
            _ = try TrackRecord.deleteOne(db, id: id)
        }
    }

    public func deleteTracksNotIn(relativePaths: Set<String>) throws {
        try dbQueue.write { db in
            if relativePaths.isEmpty {
                _ = try PlaylistTrackRecord.deleteAll(db)
                _ = try TrackRecord.deleteAll(db)
            } else {
                _ = try PlaylistTrackRecord.filter(!relativePaths.contains(Column("trackFileURL"))).deleteAll(db)
                _ = try TrackRecord.filter(!relativePaths.contains(Column("fileURL"))).deleteAll(db)
            }
            try Self.sweepOrphanedAlbumEnrichment(in: db)
        }
    }

    /// Drops enrichment state for albums the library no longer contains, for
    /// callers that retitle without deleting a track — an AI identification
    /// pass rewrites `albumTitle`/`artist`, which changes the key, so the old
    /// one would otherwise keep its exhausted verdict and keep inflating the
    /// report's "Gave up" count forever. Run it once per batch: it is a
    /// full-table anti-join, not per-row work.
    public func sweepOrphanedAlbumEnrichment() throws {
        try dbQueue.write { db in try Self.sweepOrphanedAlbumEnrichment(in: db) }
    }

    /// Drops enrichment state for albums the library no longer contains, in the
    /// same transaction as the track delete so the two can never disagree. An
    /// AI retitle changes the key, so the renamed album arrives as a new pending
    /// entity instead of inheriting the old one's exhausted verdict.
    private static func sweepOrphanedAlbumEnrichment(in db: Database) throws {
        try db.execute(sql: """
            DELETE FROM enrichmentState
            WHERE scope = 'album'
              AND key NOT IN (
                  SELECT flaccy_norm(albumTitle) || char(31) || flaccy_norm(artist)
                  FROM tracks WHERE albumTitle <> ''
              )
            """)
    }

    public func setPlayCount(relativePath: String, count: Int) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE tracks SET playCount = ? WHERE fileURL = ?", arguments: [count, relativePath])
        }
    }

    func rewriteAlbumTitle(from oldTitle: String, to newTitle: String, artist: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE tracks SET albumTitle = ? WHERE albumTitle = ? AND artist = ?", arguments: [newTitle, oldTitle, artist])
        }
    }

    /// Applies a whole library-hygiene plan in ONE transaction: album-info of
    /// each redundant variant is COALESCE-merged into the canonical album, the
    /// variant tracks are retitled, and each surviving duplicate keeper inherits
    /// the loved flag and highest play count of its group. File trashing happens
    /// outside this call (files can't participate in a DB transaction).
    public func applyHygiene(
        retitles: [AlbumRetitle],
        keeperUpdates: [KeeperUpdate],
        albumInfoMerges: [AlbumInfoMerge],
        loserRelativePaths: [String]
    ) throws {
        try dbQueue.write { db in
            for path in loserRelativePaths {
                _ = try PlaylistTrackRecord.filter(Column("trackFileURL") == path).deleteAll(db)
                _ = try TrackRecord.filter(Column("fileURL") == path).deleteAll(db)
            }
            for merge in albumInfoMerges {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO albumInfo (title, artist) VALUES (?, ?)",
                    arguments: [merge.canonicalTitle, merge.canonicalArtist]
                )
                for variant in merge.variants where !(variant.title == merge.canonicalTitle && variant.artist == merge.canonicalArtist) {
                    try db.execute(sql: """
                        UPDATE albumInfo SET
                            coverArtURL = COALESCE(coverArtURL, (SELECT coverArtURL FROM albumInfo WHERE title = :vt AND artist = :va)),
                            coverArtData = COALESCE(coverArtData, (SELECT coverArtData FROM albumInfo WHERE title = :vt AND artist = :va)),
                            customCoverData = COALESCE(customCoverData, (SELECT customCoverData FROM albumInfo WHERE title = :vt AND artist = :va)),
                            musicBrainzID = COALESCE(musicBrainzID, (SELECT musicBrainzID FROM albumInfo WHERE title = :vt AND artist = :va)),
                            year = COALESCE(year, (SELECT year FROM albumInfo WHERE title = :vt AND artist = :va)),
                            genre = COALESCE(genre, (SELECT genre FROM albumInfo WHERE title = :vt AND artist = :va)),
                            lastFetched = COALESCE(lastFetched, (SELECT lastFetched FROM albumInfo WHERE title = :vt AND artist = :va))
                        WHERE title = :ct AND artist = :ca
                    """, arguments: ["vt": variant.title, "va": variant.artist, "ct": merge.canonicalTitle, "ca": merge.canonicalArtist])
                    try db.execute(
                        sql: "DELETE FROM albumInfo WHERE title = ? AND artist = ?",
                        arguments: [variant.title, variant.artist]
                    )
                }
            }
            for retitle in retitles {
                try db.execute(
                    sql: "UPDATE tracks SET albumTitle = ?, artist = ? WHERE albumTitle = ? AND artist = ?",
                    arguments: [retitle.toTitle, retitle.toArtist, retitle.fromTitle, retitle.fromArtist]
                )
            }
            for update in keeperUpdates {
                try db.execute(
                    sql: "UPDATE tracks SET loved = ?, playCount = ? WHERE fileURL = ?",
                    arguments: [update.loved, update.playCount, update.relativePath]
                )
            }
            try Self.sweepOrphanedAlbumEnrichment(in: db)
        }
    }

    func findTrack(title: String, artist: String) throws -> TrackRecord? {
        try dbQueue.read { db in
            try TrackRecord
                .filter(Column("title").collating(.nocase) == title && Column("artist").collating(.nocase) == artist)
                .fetchOne(db)
        }
    }

    public func fetchRecentlyPlayedAlbums(limit: Int) throws -> [(albumTitle: String, artist: String)] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT DISTINCT albumTitle, COALESCE(NULLIF(albumArtist, ''), artist) AS artist
                FROM tracks
                WHERE lastPlayed IS NOT NULL
                ORDER BY lastPlayed DESC
                LIMIT ?
            """, arguments: [limit])
            return rows.map { (albumTitle: $0["albumTitle"], artist: $0["artist"]) }
        }
    }
}
