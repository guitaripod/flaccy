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

    /// Hands `onChange` every playlist, newest first, on the main queue: once
    /// now and again after each write that touches the playlists table, from
    /// this device or a server sync, until the returned token is cancelled or
    /// released. Covers are never read.
    public func observePlaylists(
        onChange: @escaping @MainActor @Sendable ([PlaylistRecord]) -> Void
    ) -> AnyDatabaseCancellable {
        ValueObservation
            .tracking { db in
                try PlaylistRecord
                    .select(Column("id"), Column("name"), Column("createdAt"))
                    .order(Column("createdAt").desc)
                    .fetchAll(db)
            }
            .start(
                in: dbQueue,
                scheduling: .async(onQueue: .main),
                onError: { error in
                    MidgarLog.error("Playlist observation failed: \(error.localizedDescription)", category: .database)
                },
                onChange: { playlists in
                    MainActor.assumeIsolated { onChange(playlists) }
                }
            )
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
                .order(Column("position").asc, Column("id").asc)
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

    /// The playlist's entries in order, each with the library's row for its
    /// song, or nil when the library no longer has it.
    public func fetchPlaylistEntries(playlistId: Int64) throws -> [PlaylistEntry] {
        try dbQueue.read { db in try Self.entries(db, playlistId: playlistId) }
    }

    /// Hands `onChange` the playlist's entries on the main queue: once now and
    /// again after every write to its songs, from this device or a server
    /// sync, until the returned token is cancelled or released.
    public func observePlaylistEntries(
        playlistId: Int64, onChange: @escaping @MainActor @Sendable ([PlaylistEntry]) -> Void
    ) -> AnyDatabaseCancellable {
        ValueObservation
            .tracking { db in try Self.entries(db, playlistId: playlistId) }
            .removeDuplicates()
            .start(
                in: dbQueue,
                scheduling: .async(onQueue: .main),
                onError: { error in
                    MidgarLog.error("Playlist entries observation failed: \(error.localizedDescription)", category: .database)
                },
                onChange: { entries in
                    MainActor.assumeIsolated { onChange(entries) }
                }
            )
    }

    /// Hands `onChange` every playlist with its song count and length on the
    /// main queue: once now and again after every change to a playlist's
    /// name, songs or length.
    public func observePlaylistSummaries(
        onChange: @escaping @MainActor @Sendable ([Int64: PlaylistSummary]) -> Void
    ) -> AnyDatabaseCancellable {
        ValueObservation
            .tracking { db in
                let names = try Row.fetchAll(db, sql: "SELECT id, name FROM playlists ORDER BY id").map { "\($0["id"] as Int64)\u{1F}\($0["name"] as String)" }
                return PlaylistsDigest(names: names, summaries: try Self.summaries(db))
            }
            .removeDuplicates()
            .map(\.summaries)
            .start(
                in: dbQueue,
                scheduling: .async(onQueue: .main),
                onError: { error in
                    MidgarLog.error("Playlist summaries observation failed: \(error.localizedDescription)", category: .database)
                },
                onChange: { summaries in
                    MainActor.assumeIsolated { onChange(summaries) }
                }
            )
    }

    private static func entries(_ db: Database, playlistId: Int64) throws -> [PlaylistEntry] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT p.id AS entryId, p.playlistId AS entryPlaylist, p.trackFileURL AS entryFile,
                       p.position AS entryPosition, t.*
                FROM playlistTracks p LEFT JOIN tracks t ON t.fileURL = p.trackFileURL
                WHERE p.playlistId = ?
                ORDER BY p.position, p.id
                """,
            arguments: [playlistId]
        )
        return try rows.map { row in
            let record = PlaylistTrackRecord(
                id: row["entryId"], playlistId: row["entryPlaylist"], trackFileURL: row["entryFile"], position: row["entryPosition"]
            )
            let track: TrackRecord? = (row["id"] as Int64?) == nil ? nil : try TrackRecord(row: row)
            return PlaylistEntry(record: record, track: track)
        }
    }

    private static func summaries(_ db: Database) throws -> [Int64: PlaylistSummary] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT p.playlistId AS id, COUNT(*) AS songs, COALESCE(SUM(t.duration), 0) AS seconds
                FROM playlistTracks p LEFT JOIN tracks t ON t.fileURL = p.trackFileURL
                GROUP BY p.playlistId
                """
        )
        return Dictionary(uniqueKeysWithValues: rows.map {
            ($0["id"] as Int64, PlaylistSummary(songCount: $0["songs"], seconds: $0["seconds"]))
        })
    }

    /// Creates a playlist holding `trackFileURLs`, each once and in the order
    /// given, in one commit, so a failure never leaves an empty playlist behind.
    @discardableResult
    public func createPlaylist(name: String, trackFileURLs: [String]) throws -> PlaylistRecord {
        try dbQueue.write { db in
            let playlist = try PlaylistRecord(name: name, createdAt: Date()).insertAndFetch(db, as: PlaylistRecord.self)
            guard let id = playlist.id else { return playlist }
            let recorder = try ServerSyncRecorder(db, gate: serverSyncGate)
            try recorder?.playlistCreated(localId: id, name: name)
            let files = PlaylistEditing.addition(existing: [], adding: trackFileURLs).added
            try appendEntries(db, playlistId: id, files: files, recorder: recorder)
            return playlist
        }
    }

    /// Appends the songs the playlist does not hold yet, in the order given,
    /// in one commit, and answers which were added and which it already held.
    @discardableResult
    public func addMissingTracksToPlaylist(playlistId: Int64, trackFileURLs: [String]) throws -> PlaylistEditing.Addition {
        try dbQueue.write { db in
            let existing = try String.fetchAll(
                db, sql: "SELECT trackFileURL FROM playlistTracks WHERE playlistId = ?", arguments: [playlistId]
            )
            let addition = PlaylistEditing.addition(existing: existing, adding: trackFileURLs)
            try appendEntries(db, playlistId: playlistId, files: addition.added, recorder: try ServerSyncRecorder(db, gate: serverSyncGate))
            return addition
        }
    }

    /// An entry taken out of a playlist: the song and the index it held, all
    /// that Undo needs to put it back.
    public struct RemovedPlaylistEntry: Sendable, Equatable {
        public let trackFileURL: String
        public let index: Int

        public init(trackFileURL: String, index: Int) {
            self.trackFileURL = trackFileURL
            self.index = index
        }
    }

    /// Takes entries out of a playlist in one commit and answers what Undo
    /// needs to put them back where they stood.
    @discardableResult
    public func removePlaylistEntries(ids: [Int64], fromPlaylist playlistId: Int64) throws -> [RemovedPlaylistEntry] {
        guard !ids.isEmpty else { return [] }
        return try dbQueue.write { db in
            let order = try PlaylistTrackRecord
                .filter(Column("playlistId") == playlistId)
                .order(Column("position").asc, Column("id").asc)
                .fetchAll(db)
            let wanted = Set(ids)
            let recorder = try ServerSyncRecorder(db, gate: serverSyncGate)
            var removed: [RemovedPlaylistEntry] = []
            for (index, entry) in order.enumerated() {
                guard let id = entry.id, wanted.contains(id) else { continue }
                try recorder?.trackRemoved(rowId: id)
                _ = try PlaylistTrackRecord.deleteOne(db, id: id)
                removed.append(RemovedPlaylistEntry(trackFileURL: entry.trackFileURL, index: index))
            }
            try renumber(db, playlistId: playlistId)
            return removed
        }
    }

    /// Puts entries that `removePlaylistEntries` took out back where they
    /// stood, in one commit.
    public func restorePlaylistEntries(_ entries: [RemovedPlaylistEntry], toPlaylist playlistId: Int64) throws {
        guard !entries.isEmpty else { return }
        try dbQueue.write { db in
            let kept = try entryIDs(db, playlistId: playlistId)
            let recorder = try ServerSyncRecorder(db, gate: serverSyncGate)
            let sorted = entries.sorted { $0.index < $1.index }
            let added = try appendEntries(db, playlistId: playlistId, files: sorted.map(\.trackFileURL), recorder: recorder)
            let order = PlaylistEditing.restored(
                kept: kept, removed: zip(added, sorted).map { (id: $0, index: $1.index) }
            )
            try applyOrder(db, playlistId: playlistId, order: order, recorder: recorder)
        }
    }

    /// Gives the playlist the order `orderedEntryIDs` in one commit; a server
    /// learns only the moves that order needs. Entries the list leaves out
    /// keep their turn after the ones it names.
    public func reorderPlaylist(playlistId: Int64, orderedEntryIDs: [Int64]) throws {
        try dbQueue.write { db in
            let current = try entryIDs(db, playlistId: playlistId)
            let named = Set(orderedEntryIDs)
            let order = orderedEntryIDs.filter(Set(current).contains) + current.filter { !named.contains($0) }
            guard order != current else { return }
            try applyOrder(db, playlistId: playlistId, order: order, recorder: try ServerSyncRecorder(db, gate: serverSyncGate))
        }
    }

    /// Makes a new playlist called `name` with the same songs in the same
    /// order and the same chosen cover, in one commit.
    @discardableResult
    public func duplicatePlaylist(id: Int64, name: String) throws -> PlaylistRecord {
        try dbQueue.write { db in
            let files = try String.fetchAll(
                db,
                sql: "SELECT trackFileURL FROM playlistTracks WHERE playlistId = ? ORDER BY position, id",
                arguments: [id]
            )
            let cover = try Data.fetchOne(
                db, sql: "SELECT customCoverData FROM playlists WHERE id = ? AND customCoverData IS NOT NULL", arguments: [id]
            )
            let copy = try PlaylistRecord(name: name, createdAt: Date()).insertAndFetch(db, as: PlaylistRecord.self)
            guard let copyId = copy.id else { return copy }
            let recorder = try ServerSyncRecorder(db, gate: serverSyncGate)
            try recorder?.playlistCreated(localId: copyId, name: name)
            try appendEntries(db, playlistId: copyId, files: files, recorder: recorder)
            if let cover {
                try db.execute(sql: "UPDATE playlists SET customCoverData = ? WHERE id = ?", arguments: [cover, copyId])
                try recorder?.coverSet(localId: copyId, data: cover)
            }
            return copy
        }
    }

    /// The playlists that hold the song at `trackFileURL`.
    public func playlistIDs(containingTrack trackFileURL: String) throws -> Set<Int64> {
        try dbQueue.read { db in
            Set(try Int64.fetchAll(
                db, sql: "SELECT DISTINCT playlistId FROM playlistTracks WHERE trackFileURL = ?", arguments: [trackFileURL]
            ))
        }
    }

    /// How many songs each playlist holds and how long the ones the library
    /// still has play, read in one query.
    public func fetchPlaylistSummaries() throws -> [Int64: PlaylistSummary] {
        try dbQueue.read { db in try Self.summaries(db) }
    }

    @discardableResult
    private func appendEntries(
        _ db: Database, playlistId: Int64, files: [String], recorder: ServerSyncRecorder?
    ) throws -> [Int64] {
        guard !files.isEmpty else { return [] }
        var position = (try Int.fetchOne(
            db, sql: "SELECT COALESCE(MAX(position), -1) FROM playlistTracks WHERE playlistId = ?", arguments: [playlistId]
        ) ?? -1) + 1
        var added: [(rowId: Int64, fileURL: String)] = []
        for file in files {
            try PlaylistTrackRecord(playlistId: playlistId, trackFileURL: file, position: position).insert(db)
            added.append((db.lastInsertedRowID, file))
            position += 1
        }
        try recorder?.tracksAdded(playlistLocalId: playlistId, rows: added)
        return added.map(\.rowId)
    }

    private func entryIDs(_ db: Database, playlistId: Int64) throws -> [Int64] {
        try Int64.fetchAll(
            db, sql: "SELECT id FROM playlistTracks WHERE playlistId = ? ORDER BY position, id", arguments: [playlistId]
        )
    }

    private func applyOrder(_ db: Database, playlistId: Int64, order: [Int64], recorder: ServerSyncRecorder?) throws {
        try recorder?.playlistReordered(localId: playlistId, orderedRowIds: order)
        let update = try db.cachedStatement(sql: "UPDATE playlistTracks SET position = ? WHERE id = ? AND playlistId = ?")
        for (position, id) in order.enumerated() {
            try update.execute(arguments: [position, id, playlistId])
        }
    }

    private func renumber(_ db: Database, playlistId: Int64) throws {
        let update = try db.cachedStatement(sql: "UPDATE playlistTracks SET position = ? WHERE id = ?")
        for (position, id) in try entryIDs(db, playlistId: playlistId).enumerated() {
            try update.execute(arguments: [position, id])
        }
    }
}

/// What the playlists list shows of every playlist, so a rename reaches it
/// although no count or length changed.
private struct PlaylistsDigest: Equatable {
    let names: [String]
    let summaries: [Int64: PlaylistSummary]
}
