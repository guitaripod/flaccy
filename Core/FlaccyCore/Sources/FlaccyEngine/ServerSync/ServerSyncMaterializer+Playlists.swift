import CryptoKit
import FlaccyCore
import Foundation
import GRDB

extension SyncMaterializer {

    private struct LocalRow {
        var rowId: Int64
        var fileURL: String
        var position: Int
    }

    static func syncPlaylist(
        _ db: Database, id: String, visible: CorePlaylistDoc?, resolver: SyncSongResolver, outcome: inout MaterializeOutcome
    ) throws {
        let find = try db.cachedStatement(sql: "SELECT id FROM playlists WHERE syncId = ?")
        let local = try Int64.fetchOne(find, arguments: [id])
        guard let doc = visible, doc.playlist.alive else {
            if let local {
                try db.execute(sql: "DELETE FROM playlists WHERE id = ?", arguments: [local])
                outcome.changes.playlists = true
            }
            try clearGhosts(db, playlist: id)
            return
        }
        let localID: Int64
        if let local {
            let rename = try db.cachedStatement(sql: "UPDATE playlists SET name = ?1 WHERE id = ?2 AND name <> ?1")
            try rename.execute(arguments: [doc.playlist.name, local])
            if db.changesCount > 0 { outcome.changes.playlists = true }
            localID = local
        } else {
            try db.execute(
                sql: "INSERT INTO playlists (name, createdAt, syncId) VALUES (?, ?, ?)",
                arguments: [doc.playlist.name, Date(timeIntervalSince1970: TimeInterval(doc.playlist.createdAt)), id]
            )
            localID = db.lastInsertedRowID
            outcome.changes.playlists = true
        }
        try syncEntries(db, localID: localID, id: id, doc: doc, resolver: resolver, outcome: &outcome)
        try syncCover(db, localID: localID, id: id, blob: doc.playlist.coverBlob, outcome: &outcome)
    }

    private static func visibleEntries(_ doc: CorePlaylistDoc) -> [CoreEntry] {
        doc.entries.filter(\.alive).sorted { left, right in
            if left.pos != right.pos { return left.pos.utf8.lexicographicallyPrecedes(right.pos.utf8) }
            return left.id.utf8.lexicographicallyPrecedes(right.id.utf8)
        }
    }

    private static func syncEntries(
        _ db: Database, localID: Int64, id: String, doc: CorePlaylistDoc, resolver: SyncSongResolver,
        outcome: inout MaterializeOutcome
    ) throws {
        var existing: [String: LocalRow] = [:]
        let fetchRows = try db.cachedStatement(
            sql: "SELECT id, syncId, trackFileURL, position FROM playlistTracks WHERE playlistId = ? AND +syncId IS NOT NULL"
        )
        for row in try Row.fetchAll(fetchRows, arguments: [localID]) {
            existing[row["syncId"]] = LocalRow(rowId: row["id"], fileURL: row["trackFileURL"], position: row["position"])
        }
        let keptKeys = try resolver.songKeys(ofRowsIn: localID)
        var shown: [(entry: CoreEntry, fileURL: String)] = []
        var hidden: [CoreEntry] = []
        for entry in visibleEntries(doc) {
            if let fileURL = try resolveEntry(resolver, existing: existing[entry.id], keptKeys: keptKeys, entry: entry) {
                shown.append((entry, fileURL))
            } else {
                hidden.append(entry)
            }
        }
        let update = try db.cachedStatement(sql: "UPDATE playlistTracks SET trackFileURL = ?, position = ? WHERE id = ?")
        let insert = try db.cachedStatement(
            sql: "INSERT INTO playlistTracks (playlistId, trackFileURL, position, syncId) VALUES (?, ?, ?, ?)"
        )
        for (position, item) in shown.enumerated() {
            if let row = existing[item.entry.id] {
                if row.fileURL == item.fileURL && row.position == position { continue }
                try update.execute(arguments: [item.fileURL, position, row.rowId])
            } else {
                try insert.execute(arguments: [localID, item.fileURL, position, item.entry.id])
            }
            outcome.changes.playlists = true
        }
        let kept = Set(shown.map(\.entry.id))
        for (entryID, row) in existing where !kept.contains(entryID) {
            try db.execute(sql: "DELETE FROM playlistTracks WHERE id = ?", arguments: [row.rowId])
            outcome.changes.playlists = true
        }
        try replaceGhosts(db, playlist: id, hidden: hidden)
    }

    private static func resolveEntry(
        _ resolver: SyncSongResolver, existing: LocalRow?, keptKeys: [String: String], entry: CoreEntry
    ) throws -> String? {
        if let existing, keptKeys[entry.id] == entry.song.songKey {
            return existing.fileURL
        }
        return try resolver.resolve(ServerCoreBridge.songRef(entry.song))
    }

    private static func clearGhosts(_ db: Database, playlist: String) throws {
        try db.execute(
            sql: "DELETE FROM sync_ghosts WHERE kind = 'entry' AND json_extract(value_json, '$.playlist') = ?",
            arguments: [playlist]
        )
    }

    private static func replaceGhosts(_ db: Database, playlist: String, hidden: [CoreEntry]) throws {
        try clearGhosts(db, playlist: playlist)
        for entry in hidden {
            let value = try ServerCoreBridge.text(GhostValue(playlist: playlist, ref: ServerCoreBridge.songRef(entry.song)))
            try db.execute(
                sql: "INSERT INTO sync_ghosts (kind, id, value_json) VALUES ('entry', ?, ?)", arguments: [entry.id, value]
            )
        }
    }

    private struct GhostValue: Encodable {
        var playlist: String
        var ref: ServerSongRef
    }

    private static func syncCover(
        _ db: Database, localID: Int64, id: String, blob: String?, outcome: inout MaterializeOutcome
    ) throws {
        let local: Data? = try Data.fetchOne(
            db, sql: "SELECT customCoverData FROM playlists WHERE id = ? AND customCoverData IS NOT NULL", arguments: [localID]
        )
        let localHash = local.map(hexDigest)
        guard let blob else {
            if let localHash, try Bool.fetchOne(
                db, sql: "SELECT EXISTS (SELECT 1 FROM sync_blobs WHERE hash = ?)", arguments: [localHash]) == true
            {
                try db.execute(sql: "UPDATE playlists SET customCoverData = NULL WHERE id = ?", arguments: [localID])
                outcome.changes.playlists = true
            }
            return
        }
        guard localHash != blob else { return }
        if let data = try Data.fetchOne(db, sql: "SELECT data FROM sync_blobs WHERE hash = ?", arguments: [blob]) {
            try db.execute(sql: "UPDATE playlists SET customCoverData = ? WHERE id = ?", arguments: [data, localID])
            outcome.changes.playlists = true
        } else {
            outcome.covers.append(ServerCoverNeed(playlistSyncID: id, hash: blob))
        }
    }

    static func hexDigest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Stores a downloaded cover for the playlist that names it, if the bytes are the hash they were fetched under.
    static func applyCover(_ db: Database, playlistSyncID: String, hash: String, data: Data) throws -> Bool {
        guard hexDigest(data) == hash else { return false }
        try db.execute(sql: "INSERT OR IGNORE INTO sync_blobs (hash, data) VALUES (?, ?)", arguments: [hash, data])
        try db.execute(
            sql: "UPDATE playlists SET customCoverData = ? WHERE syncId = ?", arguments: [data, playlistSyncID]
        )
        return db.changesCount > 0
    }
}
