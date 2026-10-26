import Foundation
import MidgarCore
import FlaccyCore
import GRDB

extension DatabaseManager {

    @discardableResult
    public func createPlaylist(name: String) throws -> PlaylistRecord {
        try dbQueue.write { db in
            let playlist = try PlaylistRecord(name: name, createdAt: Date())
                .insertAndFetch(db, as: PlaylistRecord.self)
            if let id = playlist.id {
                try ServerSyncRecorder(db, gate: serverSyncGate)?.playlistCreated(localId: id, name: name)
            }
            return playlist
        }
    }

    /// Renames a playlist in place, keeping its tracks, its cover and its identity on every device that syncs it.
    public func renamePlaylist(id: Int64, name: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE playlists SET name = ? WHERE id = ?", arguments: [name, id])
            try ServerSyncRecorder(db, gate: serverSyncGate)?.playlistRenamed(localId: id, name: name)
        }
    }

    /// The picture a person chose for this playlist, or nil while it shows the
    /// automatic mosaic of its albums.
    public func playlistCover(id: Int64) throws -> Data? {
        try dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT customCoverData FROM playlists WHERE id = ? AND customCoverData IS NOT NULL",
                arguments: [id]
            )?["customCoverData"]
        }
    }

    public func savePlaylistCover(_ data: Data, id: Int64) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE playlists SET customCoverData = ? WHERE id = ?", arguments: [data, id])
            try ServerSyncRecorder(db, gate: serverSyncGate)?.coverSet(localId: id, data: data)
        }
    }

    public func clearPlaylistCover(id: Int64) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE playlists SET customCoverData = NULL WHERE id = ?", arguments: [id])
            try ServerSyncRecorder(db, gate: serverSyncGate)?.coverCleared(localId: id)
        }
    }

    public func hasPlaylistCover(id: Int64) -> Bool {
        (try? playlistCover(id: id)) != nil
    }

    public func playlistIdsWithCovers() throws -> Set<Int64> {
        try dbQueue.read { db in
            Set(try Int64.fetchAll(db, sql: "SELECT id FROM playlists WHERE customCoverData IS NOT NULL"))
        }
    }

    public func deletePlaylist(id: Int64) throws {
        try dbQueue.write { db in
            try ServerSyncRecorder(db, gate: serverSyncGate)?.playlistDeleted(localId: id)
            _ = try PlaylistRecord.deleteOne(db, id: id)
        }
    }

    public func fetchAllPlaylists() throws -> [PlaylistRecord] {
        try dbQueue.read { db in
            try PlaylistRecord.order(Column("createdAt").desc).fetchAll(db)
        }
    }

    public func addTrackToPlaylist(playlistId: Int64, trackFileURL: String) throws {
        try dbQueue.write { db in
            let maxPosition = try Int.fetchOne(
                db,
                sql: "SELECT COALESCE(MAX(position), -1) FROM playlistTracks WHERE playlistId = ?",
                arguments: [playlistId]
            ) ?? -1

            try PlaylistTrackRecord(
                playlistId: playlistId,
                trackFileURL: trackFileURL,
                position: maxPosition + 1
            ).insert(db)
            try ServerSyncRecorder(db, gate: serverSyncGate)?.tracksAdded(
                playlistLocalId: playlistId, rows: [(db.lastInsertedRowID, trackFileURL)]
            )
        }
    }

    /// Appends many tracks in the order given inside one transaction, so saving
    /// a long list as a playlist is a single commit rather than one per song.
    public func addTracksToPlaylist(playlistId: Int64, trackFileURLs: [String]) throws {
        guard !trackFileURLs.isEmpty else { return }
        try dbQueue.write { db in
            var position = (try Int.fetchOne(
                db,
                sql: "SELECT COALESCE(MAX(position), -1) FROM playlistTracks WHERE playlistId = ?",
                arguments: [playlistId]
            ) ?? -1) + 1
            var added: [(rowId: Int64, fileURL: String)] = []
            for trackFileURL in trackFileURLs {
                try PlaylistTrackRecord(playlistId: playlistId, trackFileURL: trackFileURL, position: position).insert(db)
                added.append((db.lastInsertedRowID, trackFileURL))
                position += 1
            }
            try ServerSyncRecorder(db, gate: serverSyncGate)?.tracksAdded(playlistLocalId: playlistId, rows: added)
        }
    }

    public func removeTrackFromPlaylist(id: Int64) throws {
        try dbQueue.write { db in
            try ServerSyncRecorder(db, gate: serverSyncGate)?.trackRemoved(rowId: id)
            _ = try PlaylistTrackRecord.deleteOne(db, id: id)
        }
    }

    public func fetchPlaylistTracks(playlistId: Int64) throws -> [PlaylistTrackRecord] {
        try dbQueue.read { db in
            try PlaylistTrackRecord
                .filter(Column("playlistId") == playlistId)
                .order(Column("position").asc)
                .fetchAll(db)
        }
    }

    func fetchPlaylistTrackCount(playlistId: Int64) throws -> Int {
        try dbQueue.read { db in
            try PlaylistTrackRecord
                .filter(Column("playlistId") == playlistId)
                .fetchCount(db)
        }
    }

    public func fetchPlaylistTrackCounts() throws -> [Int64: Int] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT playlistId, COUNT(*) AS trackCount FROM playlistTracks GROUP BY playlistId")
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["playlistId"] as Int64, $0["trackCount"] as Int) })
        }
    }

    public func reorderPlaylistTrack(id: Int64, newPosition: Int) throws {
        try dbQueue.write { db in
            if var record = try PlaylistTrackRecord.fetchOne(db, id: id) {
                let recorder = try ServerSyncRecorder(db, gate: serverSyncGate)
                let witness = try recorder?.beginMove(rowId: id)
                record.position = newPosition
                try record.update(db)
                try recorder?.endMove(witness)
            }
        }
    }
}
