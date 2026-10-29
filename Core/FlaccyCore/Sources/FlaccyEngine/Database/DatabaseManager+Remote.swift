import Foundation
import MidgarCore
import FlaccyCore
import GRDB

extension DatabaseManager {

    public func fetchRemoteServers() throws -> [RemoteServerRecord] {
        try dbQueue.read { db in
            try RemoteServerRecord.order(Column("addedAt").asc, Column("id").asc).fetchAll(db)
        }
    }

    public func fetchRemoteServer(id: String) throws -> RemoteServerRecord? {
        try dbQueue.read { db in
            try RemoteServerRecord.fetchOne(db, key: id)
        }
    }

    public func saveRemoteServer(_ server: RemoteServerRecord) throws {
        try dbQueue.write { db in
            try server.save(db)
        }
    }

    public func markRemoteServerSynced(id: String, at date: Date) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE remoteServers SET lastSyncedAt = ? WHERE id = ?", arguments: [date, id])
        }
    }

    /// Removes a server with everything that came from it: its songs, the playlist places
    /// that held them, and the enrichment state of albums that only it contributed.
    /// Returns the paths of the songs that were removed.
    @discardableResult
    public func deleteRemoteServer(id: String) throws -> [String] {
        try dbQueue.write { db in
            let paths = try String.fetchAll(db, sql: "SELECT fileURL FROM tracks WHERE remoteServer = ?", arguments: [id])
            try Self.deleteRemoteRows(paths: paths, in: db)
            _ = try RemoteServerRecord.deleteOne(db, key: id)
            try Self.sweepOrphanedAlbumEnrichment(in: db)
            return paths
        }
    }

    /// Removes the songs of a server from the library and keeps the server, its sign-in and the playlist places that held them,
    /// so showing the music again brings every place back. Returns the paths of the songs that were removed.
    @discardableResult
    public func deleteRemoteTracks(serverID: String) throws -> [String] {
        try dbQueue.write { db in
            let paths = try String.fetchAll(db, sql: "SELECT fileURL FROM tracks WHERE remoteServer = ?", arguments: [serverID])
            _ = try TrackRecord.filter(Column("remoteServer") == serverID).deleteAll(db)
            try db.execute(sql: "UPDATE remoteServers SET lastSyncedAt = NULL WHERE id = ?", arguments: [serverID])
            try Self.sweepOrphanedAlbumEnrichment(in: db)
            return paths
        }
    }

    /// The stored paths of every song of a server.
    public func fetchRemoteTrackPaths(serverID: String) throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT fileURL FROM tracks WHERE remoteServer = ?", arguments: [serverID])
        }
    }

    /// How many songs each server holds in the library, by server id.
    public func fetchRemoteSongCounts() throws -> [String: Int] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT remoteServer, COUNT(*) AS songs FROM tracks WHERE remoteServer IS NOT NULL GROUP BY remoteServer
                """)
            return Dictionary(uniqueKeysWithValues: rows.compactMap { row -> (String, Int)? in
                guard let server: String = row["remoteServer"] else { return nil }
                return (server, row["songs"])
            })
        }
    }

    /// The songs of a server as the sync compares them with the server's catalog.
    public func fetchRemoteCatalogItems(serverID: String) throws -> [RemoteCatalogDiff.Item] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT fileURL, remoteSize, duration, title, artist, albumTitle, trackNumber, audioFingerprint
                FROM tracks WHERE remoteServer = ?
                """, arguments: [serverID])
            return rows.compactMap { row in
                let path: String = row["fileURL"]
                guard let song = RemoteTrackPath(path: path) else { return nil }
                return RemoteCatalogDiff.Item(
                    id: song.songID,
                    size: row["remoteSize"],
                    duration: row["duration"],
                    title: row["title"],
                    artist: row["artist"],
                    album: row["albumTitle"],
                    track: row["trackNumber"],
                    fingerprint: row["audioFingerprint"]
                )
            }
        }
    }

    /// What the row of a remote song says about its file, or nil when no row has that path.
    public func fetchRemoteSongSource(path: String) throws -> RemoteSongSource? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT remoteSuffix, remoteSize, duration, pinned FROM tracks WHERE fileURL = ? AND remoteServer IS NOT NULL
                """, arguments: [path]) else { return nil }
            return RemoteSongSource(
                path: path,
                suffix: row["remoteSuffix"],
                size: row["remoteSize"],
                duration: row["duration"],
                pinned: row["pinned"]
            )
        }
    }

    /// The paths of every remote song that sits in the same album as `path`, in track order.
    public func fetchRemoteAlbumPaths(containing path: String) throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT b.fileURL FROM tracks a
                JOIN tracks b ON b.remoteServer = a.remoteServer AND b.albumTitle = a.albumTitle AND b.artist = a.artist
                WHERE a.fileURL = ? AND a.remoteServer IS NOT NULL
                ORDER BY b.trackNumber, b.title
                """, arguments: [path])
        }
    }

    public func setRemotePinned(paths: [String], pinned: Bool) throws {
        guard !paths.isEmpty else { return }
        try dbQueue.write { db in
            for path in paths {
                try db.execute(
                    sql: "UPDATE tracks SET pinned = ? WHERE fileURL = ? AND remoteServer IS NOT NULL",
                    arguments: [pinned, path]
                )
            }
        }
    }

    public func fetchPinnedRemotePaths(serverID: String? = nil) throws -> [String] {
        try dbQueue.read { db in
            if let serverID {
                return try String.fetchAll(
                    db, sql: "SELECT fileURL FROM tracks WHERE pinned = 1 AND remoteServer = ?", arguments: [serverID]
                )
            }
            return try String.fetchAll(db, sql: "SELECT fileURL FROM tracks WHERE pinned = 1 AND remoteServer IS NOT NULL")
        }
    }

    /// Applies one catalog diff. Every kind of change lands in one transaction, so a sync that
    /// fails halfway leaves the rows exactly as they were.
    public func applyRemoteCatalog(_ change: RemoteCatalogChange) throws {
        try dbQueue.write { db in
            for (songID, facts) in change.inserts {
                let path = RemoteTrackPath(serverID: change.serverID, songID: songID).path
                try Self.newRemoteRow(path: path, serverID: change.serverID, facts: facts, now: change.now)
                    .insert(db, onConflict: .ignore)
            }
            for (songID, facts) in change.updates {
                let path = RemoteTrackPath(serverID: change.serverID, songID: songID).path
                try Self.refreshRemoteMetadata(path: path, facts: facts, in: db)
            }
            for (songID, facts) in change.newVersions {
                let path = RemoteTrackPath(serverID: change.serverID, songID: songID).path
                try Self.refreshRemoteMetadata(path: path, facts: facts, in: db)
                try Self.refreshRemoteFile(path: path, facts: facts, in: db)
                try Self.bumpRevision(path: path, now: change.now, in: db)
            }
            for state in change.playStates {
                let path = RemoteTrackPath(serverID: change.serverID, songID: state.songID).path
                try Self.adoptPlayState(state, path: path, in: db)
            }
            let removed = change.removedSongIDs.map { RemoteTrackPath(serverID: change.serverID, songID: $0).path }
            try Self.deleteRemoteRows(paths: removed, in: db)
            try Self.sweepOrphanedAlbumEnrichment(in: db)
        }
    }

    /// Records that the server now serves different bytes under a song's name: the new size,
    /// the next revision, and the time, exactly as a catalog sync records a new version.
    /// Returns false when no row has that path.
    @discardableResult
    public func bumpRemoteRevision(path: String, size: Int64?, now: Date) throws -> Bool {
        try dbQueue.write { db in
            guard try Row.fetchOne(
                db, sql: "SELECT 1 FROM tracks WHERE fileURL = ? AND remoteServer IS NOT NULL", arguments: [path]
            ) != nil else { return false }
            if let size {
                try db.execute(sql: "UPDATE tracks SET remoteSize = ?, fileSize = ? WHERE fileURL = ?", arguments: [size, size, path])
            }
            try Self.bumpRevision(path: path, now: now, in: db)
            return true
        }
    }

    private static func newRemoteRow(path: String, serverID: String, facts: RemoteSongFacts, now: Date) -> TrackRecord {
        TrackRecord(
            fileURL: path,
            title: facts.title,
            artist: facts.artist,
            albumTitle: facts.albumTitle,
            albumArtist: facts.albumArtist,
            trackNumber: facts.trackNumber,
            duration: facts.duration,
            dateAdded: now,
            playCount: 0,
            aiAnalyzed: true,
            analysisAttemptedAt: now,
            codec: facts.codec,
            bitDepth: facts.bitDepth,
            sampleRate: facts.sampleRate,
            channels: facts.channels,
            fileSize: facts.size,
            audioFingerprint: facts.fingerprint,
            remoteServer: serverID,
            remoteSuffix: facts.suffix,
            remoteSize: facts.size,
            remoteCoverArt: facts.coverArt,
            remoteAlbumId: facts.albumId
        )
    }

    private static func refreshRemoteMetadata(path: String, facts: RemoteSongFacts, in db: Database) throws {
        let values: [(any DatabaseValueConvertible)?] = [
            facts.title, facts.artist, facts.albumTitle, facts.albumArtist, facts.trackNumber,
            facts.coverArt, facts.albumId, path,
        ]
        try db.execute(sql: """
            UPDATE tracks SET title = ?, artist = ?, albumTitle = ?, albumArtist = ?, trackNumber = ?,
                remoteCoverArt = ?, remoteAlbumId = ?
            WHERE fileURL = ? AND remoteServer IS NOT NULL
            """, arguments: StatementArguments(values))
    }

    private static func refreshRemoteFile(path: String, facts: RemoteSongFacts, in db: Database) throws {
        let values: [(any DatabaseValueConvertible)?] = [
            facts.duration, facts.suffix, facts.size, facts.size, facts.fingerprint,
            facts.codec, facts.bitDepth, facts.sampleRate, facts.channels, path,
        ]
        try db.execute(sql: """
            UPDATE tracks SET duration = ?, remoteSuffix = ?, remoteSize = ?, fileSize = ?, audioFingerprint = ?,
                codec = ?, bitDepth = ?, sampleRate = ?, channels = ?
            WHERE fileURL = ? AND remoteServer IS NOT NULL
            """, arguments: StatementArguments(values))
    }

    /// Follows the person across devices through the server: a star becomes a love unless a love
    /// or unlove is still waiting to be sent, the play count never goes down, and the last play is the later one.
    private static func adoptPlayState(_ state: RemoteSongPlayState, path: String, in db: Database) throws {
        let values: [(any DatabaseValueConvertible)?] = [
            state.starred, state.playCount, state.played, state.played, state.played, path,
        ]
        try db.execute(sql: """
            UPDATE tracks SET
                loved = CASE WHEN lovedPendingOp IS NULL THEN ? ELSE loved END,
                playCount = MAX(playCount, COALESCE(?, 0)),
                lastPlayed = CASE WHEN ? IS NOT NULL AND (lastPlayed IS NULL OR lastPlayed < ?) THEN ? ELSE lastPlayed END
            WHERE fileURL = ? AND remoteServer IS NOT NULL
            """, arguments: StatementArguments(values))
    }

    private static func bumpRevision(path: String, now: Date, in db: Database) throws {
        try db.execute(
            sql: "UPDATE tracks SET revision = revision + 1, revisedAt = ? WHERE fileURL = ?",
            arguments: [now, path]
        )
    }

    private static func deleteRemoteRows(paths: [String], in db: Database) throws {
        for path in paths {
            _ = try PlaylistTrackRecord.filter(Column("trackFileURL") == path).deleteAll(db)
            _ = try TrackRecord.filter(Column("fileURL") == path).deleteAll(db)
        }
    }
}
