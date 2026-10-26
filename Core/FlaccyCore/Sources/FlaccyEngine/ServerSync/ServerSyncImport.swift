import CryptoKit
import FlaccyCore
import Foundation
import GRDB

/// What the first connect queued.
public struct ServerSyncImportReport: Sendable, Equatable {
    public var playlists = 0
    public var entries = 0
    public var loves = 0
    public var covers = 0

    public init() {}
}

/// The first connect (PROTOCOL.md section 13): what a database that already holds playlists, loves and plays hands to a server it
/// has just enrolled with. Playlists and entries get ids every device derives identically, loves and covers go out at the import
/// floor stamp so any real action wins over them, and plays go out as migrated listens in batches of 500.
enum SyncImport {

    static let floorStamp: Int64 = Int64(1_577_836_800_000) << 16
    static let listenChunk = 5_000

    /// Queues the local playlists, entries, covers and loves, in the caller's transaction.
    static func queueStructure(_ db: Database, nowMs: Int64) throws -> ServerSyncImportReport {
        var report = ServerSyncImportReport()
        try importPlaylists(db, nowMs: nowMs, report: &report)
        try importLoves(db, nowMs: nowMs, report: &report)
        try SyncMeta.setInt(db, SyncMeta.importCursor, 0)
        return report
    }

    private static func importPlaylists(_ db: Database, nowMs: Int64, report: inout ServerSyncImportReport) throws {
        let playlists = try Row.fetchAll(
            db, sql: "SELECT id, name, syncId, customCoverData FROM playlists ORDER BY createdAt, id"
        )
        var taken = Set<String>()
        for row in playlists {
            let localID: Int64 = row["id"]
            let name: String = row["name"]
            let normalized = try ServerCoreBridge.normalizePlaylistName(name)
            let derived = try ServerCoreBridge.playlistId(name: name, occurrence: 0)
            let id: String
            if let known: String = row["syncId"] {
                id = known
                if known == derived { taken.insert(normalized) }
            } else {
                id = taken.insert(normalized).inserted ? derived : ServerSyncIDs.uuidV7(nowMs: nowMs)
                try db.execute(sql: "UPDATE playlists SET syncId = ? WHERE id = ?", arguments: [id, localID])
            }
            let touches = [SyncPending.playlistKey(id)]
            try SyncPending.append(
                db, NewMutation("playlist.create", ["id": .string(id), "name": .string(name)], touches: touches),
                nowMs: nowMs
            )
            report.playlists += 1
            report.entries += try importEntries(db, localID: localID, playlist: id, touches: touches, nowMs: nowMs)
            if let cover: Data = row["customCoverData"], !cover.isEmpty, cover.count <= 2 * 1024 * 1024 {
                try queueCover(db, playlist: id, data: cover, touches: touches, nowMs: nowMs)
                report.covers += 1
            }
        }
    }

    private static func queueCover(_ db: Database, playlist: String, data: Data, touches: [String], nowMs: Int64) throws {
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try db.execute(sql: "INSERT OR IGNORE INTO sync_blobs (hash, data) VALUES (?, ?)", arguments: [hash, data])
        try SyncPending.append(
            db,
            NewMutation("playlist.setCover", ["id": .string(playlist), "blob": .string(hash)], touches: touches, stamp: floorStamp),
            nowMs: nowMs
        )
    }

    private static func importEntries(
        _ db: Database, localID: Int64, playlist: String, touches: [String], nowMs: Int64
    ) throws -> Int {
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT id, trackFileURL, syncId FROM playlistTracks WHERE playlistId = ? ORDER BY position, id",
            arguments: [localID]
        )
        var occurrences: [String: UInt32] = [:]
        var previous: String?
        var queued = 0
        for row in rows {
            guard let song = try SyncSongRefs.ref(db, fileURL: row["trackFileURL"]) else { continue }
            let seen = occurrences[song.songKey, default: 0]
            occurrences[song.songKey] = seen + 1
            let entry: String
            if let known: String = row["syncId"] {
                entry = known
            } else {
                entry = try ServerCoreBridge.entryId(playlistId: playlist, songKey: song.songKey, occurrence: seen)
                try db.execute(sql: "UPDATE playlistTracks SET syncId = ? WHERE id = ?", arguments: [entry, row["id"] as Int64])
            }
            let place: ServerJSON = previous.map { ["kind": "after", "id": .string($0)] } ?? ["kind": "last"]
            let args: ServerJSON = [
                "id": .string(entry), "playlist": .string(playlist), "ref": try ServerCoreBridge.json(song), "place": place,
            ]
            try SyncPending.append(db, NewMutation("entry.insert", args, touches: touches), nowMs: nowMs)
            previous = entry
            queued += 1
        }
        return queued
    }

    private static func importLoves(_ db: Database, nowMs: Int64, report: inout ServerSyncImportReport) throws {
        let loved = try String.fetchAll(db, sql: "SELECT fileURL FROM tracks WHERE loved = 1 ORDER BY fileURL")
        var seen = Set<String>()
        for fileURL in loved {
            guard let song = try SyncSongRefs.ref(db, fileURL: fileURL), seen.insert(song.songKey).inserted else { continue }
            let args: ServerJSON = [
                "songKey": .string(song.songKey), "ref": try ServerCoreBridge.json(song), "loved": true,
            ]
            try SyncPending.append(
                db,
                NewMutation("love.set", args, touches: [SyncPending.loveKey(song.songKey)], stamp: floorStamp),
                nowMs: nowMs
            )
            report.loves += 1
        }
    }

    /// Gives the next chunk of stored plays their migrated ids and queues them. A repeat of the same second, title and artist
    /// is hidden locally, as the server's ledger hides it. Answers how many plays were queued and whether none are left.
    static func importListens(_ db: Database, nowMs: Int64) throws -> (queued: Int, done: Bool) {
        let cursor = try SyncMeta.int(db, SyncMeta.importCursor) ?? 0
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, eventId, CAST(strftime('%s', timestamp) AS INTEGER) AS ts, trackTitle, artist, albumTitle,
                       duration, titleKey, artistKey, albumKey
                FROM scrobbles WHERE id > ? ORDER BY id LIMIT ?
                """,
            arguments: [cursor, listenChunk]
        )
        guard let last = rows.last else {
            try SyncMeta.set(db, SyncMeta.imported, "1")
            return (0, true)
        }
        var memo = ListenKeyMemo()
        var plays = try assignEventIDs(db, rows: rows, memo: &memo)
        plays = plays.filter { $0.ts >= 0 }
        for batch in try SyncListens.listenDocuments(plays).chunked(into: SyncListens.batchSize) {
            try SyncPending.append(db, SyncListens.recordMutation(batch), nowMs: nowMs)
        }
        try SyncMeta.setInt(db, SyncMeta.importCursor, last["id"])
        return (plays.count, false)
    }

    private static func assignEventIDs(_ db: Database, rows: [Row], memo: inout ListenKeyMemo) throws -> [StoredPlay] {
        var plays: [StoredPlay] = []
        var pending: [(row: Row, play: StoredPlay)] = []
        for row in rows {
            let title: String = row["trackTitle"]
            let artist: String = row["artist"]
            let album: String = row["albumTitle"]
            var titleKey: String = row["titleKey"]
            var artistKey: String = row["artistKey"]
            var albumKey: String = row["albumKey"]
            if titleKey.isEmpty {
                let keys = memo.keys(title: title, artist: artist, album: album)
                (titleKey, artistKey, albumKey) = (keys.title, keys.artist, keys.album)
            }
            let play = StoredPlay(
                eventId: row["eventId"] ?? "", ts: row["ts"], title: title, artist: artist, album: album,
                duration: row["duration"], titleKey: titleKey, artistKey: artistKey, albumKey: albumKey
            )
            if play.eventId.isEmpty { pending.append((row, play)) } else { plays.append(play) }
        }
        let valid = pending.filter { $0.play.ts >= 0 }
        let ids = try ServerCoreBridge.eventIdsMig(valid.map { ($0.play.ts, $0.play.titleKey, $0.play.artistKey) })
        var taken = Set<String>()
        for (item, id) in zip(valid, ids) {
            let known = try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM scrobbles WHERE eventId = ?)", arguments: [id]) ?? false
            if known || !taken.insert(id).inserted {
                try db.execute(sql: "UPDATE scrobbles SET suppressed = 1 WHERE id = ?", arguments: [item.row["id"] as Int64])
                continue
            }
            try db.execute(sql: "UPDATE scrobbles SET eventId = ? WHERE id = ?", arguments: [id, item.row["id"] as Int64])
            var play = item.play
            play.eventId = id
            plays.append(play)
        }
        return plays
    }
}
