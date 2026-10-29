import CryptoKit
import FlaccyCore
import Foundation
import GRDB

/// What the first connect queued, counted as it goes.
public struct ServerSyncImportReport: Sendable, Equatable {
    public var playlists = 0
    public var entries = 0
    public var loves = 0
    public var covers = 0

    public init() {}

    mutating func add(_ other: ServerSyncImportReport) {
        playlists += other.playlists
        entries += other.entries
        loves += other.loves
        covers += other.covers
    }
}

/// Playlist names compared the way the first-connect merge compares them, asked of the core once per spelling.
final class NormalizedPlaylistNames: @unchecked Sendable {

    static let shared = NormalizedPlaylistNames()

    private let lock = NSLock()
    private var known: [String: String] = [:]

    func normalized(_ name: String) throws -> String {
        if let found = lock.withLock({ known[name] }) { return found }
        let computed = try ServerCoreBridge.normalizePlaylistName(name)
        lock.withLock { known[name] = computed }
        return computed
    }
}

/// The first connect (PROTOCOL.md section 13): what a database that already holds playlists, loves and plays hands to a server it
/// has just enrolled with. Playlists and entries get ids every device derives identically, loves and covers go out at the import
/// floor stamp so any real action wins over them, and plays go out as migrated listens in batches of 500.
///
/// The work is cut into steps that each commit in a few milliseconds, so the person's own writes never wait on it, and it is
/// resumable: its place is kept in `sync_meta` as cursors over row ids. Writes made while it runs are recorded as usual; a row
/// the import has not reached yet is recorded by the import itself, from its state at that moment.
enum SyncImport {

    static let floorStamp: Int64 = Int64(1_577_836_800_000) << 16
    static let playlistBatch = 100
    static let entryChunk = 300
    static let loveChunk = 400
    static let listenChunk = 300
    static let maxCoverBytes = 2 * 1024 * 1024

    static let playlistFloor = "import_playlist_floor"
    static let playlistCursor = "import_playlist_cursor"
    static let entryFloor = "import_entry_floor"
    static let entryCursor = "import_entry_cursor"
    static let loveCursor = "import_love_cursor"
    static let structureDone = "structure_imported"

    /// Marks everything the library holds now as waiting to be imported, and imports the first playlists, in the caller's transaction.
    static func begin(_ db: Database, nowMs: Int64) throws -> ServerSyncImportReport {
        try SyncMeta.setInt(db, playlistFloor, try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(id), 0) FROM playlists") ?? 0)
        try SyncMeta.setInt(db, playlistCursor, 0)
        try SyncMeta.setInt(db, entryFloor, try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(id), 0) FROM playlistTracks") ?? 0)
        try SyncMeta.setInt(db, entryCursor, 0)
        try SyncMeta.setInt(db, loveCursor, 0)
        try SyncMeta.remove(db, structureDone)
        return try importPlaylistBatch(db, nowMs: nowMs).report
    }

    static func isStructureDone(_ db: Database) throws -> Bool {
        try SyncMeta.get(db, structureDone) != nil
    }

    /// One bounded unit of the structure import. Answers what it queued and true once nothing is left.
    static func step(_ db: Database, nowMs: Int64) throws -> (report: ServerSyncImportReport, done: Bool) {
        let playlists = try importPlaylistBatch(db, nowMs: nowMs)
        if playlists.consumed { return (playlists.report, false) }
        let entries = try importEntries(db, nowMs: nowMs)
        if entries.consumed { return (entries.report, false) }
        let loves = try importLoves(db, nowMs: nowMs)
        if loves.consumed { return (loves.report, false) }
        try SyncMeta.set(db, structureDone, "1")
        return (ServerSyncImportReport(), true)
    }

    private static func importPlaylistBatch(_ db: Database, nowMs: Int64) throws -> (report: ServerSyncImportReport, consumed: Bool) {
        var report = ServerSyncImportReport()
        let cursor = try SyncMeta.int(db, playlistCursor) ?? 0
        let floor = try SyncMeta.int(db, playlistFloor) ?? 0
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT id, name, syncId, createdAt, customCoverData FROM playlists WHERE id > ? AND id <= ? ORDER BY id LIMIT ?",
            arguments: [cursor, floor, playlistBatch]
        )
        guard let last = rows.last else { return (report, false) }
        var batch: [NewMutation] = []
        for row in rows {
            try queuePlaylist(db, row: row, nowMs: nowMs, into: &batch, report: &report)
        }
        try SyncPending.appendAll(db, batch, nowMs: nowMs)
        try SyncMeta.setInt(db, playlistCursor, last["id"])
        return (report, true)
    }

    /// Gives a playlist the import has not reached yet its identity and its `playlist.create`, for a write that needs it now.
    static func ensurePlaylist(_ db: Database, localID: Int64, nowMs: Int64) throws -> String? {
        let cursor = try SyncMeta.int(db, playlistCursor) ?? 0
        let floor = try SyncMeta.int(db, playlistFloor) ?? 0
        guard localID > cursor, localID <= floor,
              let row = try Row.fetchOne(
                  db, sql: "SELECT id, name, syncId, createdAt, customCoverData FROM playlists WHERE id = ?", arguments: [localID])
        else { return nil }
        var report = ServerSyncImportReport()
        var batch: [NewMutation] = []
        let id = try queuePlaylist(db, row: row, nowMs: nowMs, into: &batch, report: &report)
        try SyncPending.appendAll(db, batch, nowMs: nowMs)
        return id
    }

    @discardableResult
    private static func queuePlaylist(
        _ db: Database, row: Row, nowMs: Int64, into batch: inout [NewMutation], report: inout ServerSyncImportReport
    ) throws -> String {
        let localID: Int64 = row["id"]
        let name: String = row["name"]
        let id: String
        if let known: String = row["syncId"] {
            id = known
        } else {
            id = try isFirstOfItsName(db, row: row)
                ? try ServerCoreBridge.playlistId(name: name, occurrence: 0)
                : ServerSyncIDs.uuidV7(nowMs: nowMs)
            try db.execute(sql: "UPDATE playlists SET syncId = ? WHERE id = ?", arguments: [id, localID])
        }
        let touches = [SyncPending.playlistKey(id)]
        batch.append(NewMutation("playlist.create", ["id": .string(id), "name": .string(name)], touches: touches))
        report.playlists += 1
        if let cover: Data = row["customCoverData"], !cover.isEmpty, cover.count <= maxCoverBytes {
            let hash = SyncMaterializer.hexDigest(cover)
            try db.execute(sql: "INSERT OR IGNORE INTO sync_blobs (hash, data) VALUES (?, ?)", arguments: [hash, cover])
            batch.append(NewMutation(
                "playlist.setCover", ["id": .string(id), "blob": .string(hash)], touches: touches, stamp: floorStamp
            ))
            report.covers += 1
        }
        return id
    }

    /// True when no playlist created before this one, or created with it and stored earlier, carries the same normalized name.
    private static func isFirstOfItsName(_ db: Database, row: Row) throws -> Bool {
        let wanted = try NormalizedPlaylistNames.shared.normalized(row["name"])
        let earlier = try String.fetchAll(
            db,
            sql: "SELECT name FROM playlists WHERE createdAt < ?1 OR (createdAt = ?1 AND id < ?2)",
            arguments: [row["createdAt"] as Date, row["id"] as Int64]
        )
        for name in earlier where try NormalizedPlaylistNames.shared.normalized(name) == wanted { return false }
        return true
    }

    private struct EntryRow {
        var rowID: Int64
        var playlistID: Int64
        var fileURL: String
        var knownID: String?
        var playlistSyncID: String?
        var song: ServerSongRef?
    }

    private static func importEntries(_ db: Database, nowMs: Int64) throws -> (report: ServerSyncImportReport, consumed: Bool) {
        var report = ServerSyncImportReport()
        let cursor = try SyncMeta.int(db, entryCursor) ?? 0
        let floor = try SyncMeta.int(db, entryFloor) ?? 0
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT pt.id, pt.playlistId, pt.trackFileURL, pt.syncId, p.syncId AS playlistSync, t.title, t.artist, t.albumTitle,
                       t.duration, t.audioFingerprint, t.musicBrainzID, k.songKey
                FROM playlistTracks pt
                LEFT JOIN playlists p ON p.id = pt.playlistId
                LEFT JOIN tracks t ON t.fileURL = pt.trackFileURL
                LEFT JOIN sync_song_keys k ON k.trackId = t.id
                WHERE pt.id > ? AND pt.id <= ? ORDER BY pt.id LIMIT ?
                """,
            arguments: [cursor, floor, entryChunk]
        )
        guard let last = rows.last else { return (report, false) }
        let entries = rows.map { row in
            EntryRow(
                rowID: row["id"], playlistID: row["playlistId"], fileURL: row["trackFileURL"], knownID: row["syncId"],
                playlistSyncID: row["playlistSync"], song: songRef(row, fileURL: row["trackFileURL"])
            )
        }
        let playlists = Set(entries.map(\.playlistID))
        var order = try playlistOrder(db, playlists, cursor: cursor, floor: floor)
        let occurrences = try occurrenceNumbers(db, playlists)
        var batch: [NewMutation] = []
        for entry in entries {
            guard let song = entry.song, let playlist = entry.playlistSyncID else { continue }
            let id: String
            if let known = entry.knownID {
                id = known
            } else {
                id = try ServerCoreBridge.entryId(
                    playlistId: playlist, songKey: song.songKey, occurrence: UInt32(occurrences[entry.rowID] ?? 0)
                )
                try db.execute(sql: "UPDATE playlistTracks SET syncId = ? WHERE id = ?", arguments: [id, entry.rowID])
            }
            let place: ServerJSON = order.anchor(of: entry.rowID).map {
                ["kind": "after", "id": .string($0)]
            } ?? (order.hasImported(in: entry.playlistID) ? ["kind": "first"] : ["kind": "last"])
            order.markImported(entry.rowID, id)
            let args: ServerJSON = [
                "id": .string(id), "playlist": .string(playlist), "ref": try ServerCoreBridge.json(song), "place": place,
            ]
            batch.append(NewMutation("entry.insert", args, touches: [SyncPending.playlistKey(playlist)]))
            report.entries += 1
        }
        try SyncPending.appendAll(db, batch, nowMs: nowMs)
        try SyncMeta.setInt(db, entryCursor, last["id"])
        return (report, true)
    }

    private static func songRef(_ row: Row, fileURL: String) -> ServerSongRef? {
        guard let songKey: String = row["songKey"], let title: String = row["title"], let artist: String = row["artist"] else {
            return nil
        }
        let album: String = row["albumTitle"] ?? ""
        let duration: Double = row["duration"] ?? 0
        let albumKey = ListenHistory.albumKey(album)
        return ServerSongRef(
            songKey: songKey, title: title, artist: artist, album: album, durationMs: Int64((duration * 1000).rounded()),
            fp: (row["audioFingerprint"] as String?).flatMap { $0.isEmpty ? nil : $0 },
            mbid: (row["musicBrainzID"] as String?).flatMap { $0.isEmpty ? nil : $0 },
            albumKey: albumKey.isEmpty ? nil : albumKey, relPath: RemoteTrackPath.isRemote(fileURL) ? nil : fileURL
        )
    }

    /// The position order of each playlist's rows, for choosing the entry a new one goes after. A row counts as placed on the server
    /// when this step imported it, an earlier step did (a lower id than the cursor), or the recorder queued it after the import began.
    private struct PlaylistOrder {
        var rows: [Int64: [(rowID: Int64, syncID: String?)]] = [:]
        var playlistOf: [Int64: Int64] = [:]
        var imported: [Int64: String] = [:]
        var cursor: Int64
        var floor: Int64

        mutating func markImported(_ rowID: Int64, _ id: String) {
            imported[rowID] = id
        }

        private func placedID(_ row: (rowID: Int64, syncID: String?)) -> String? {
            if let id = imported[row.rowID] { return id }
            guard row.rowID <= cursor || row.rowID > floor else { return nil }
            return row.syncID
        }

        func anchor(of rowID: Int64) -> String? {
            guard let playlist = playlistOf[rowID], let list = rows[playlist],
                  let index = list.firstIndex(where: { $0.rowID == rowID })
            else { return nil }
            return list[..<index].reversed().lazy.compactMap(placedID).first
        }

        func hasImported(in playlist: Int64) -> Bool {
            (rows[playlist] ?? []).contains { placedID($0) != nil }
        }
    }

    private static func playlistOrder(_ db: Database, _ playlists: Set<Int64>, cursor: Int64, floor: Int64) throws -> PlaylistOrder {
        var order = PlaylistOrder(cursor: cursor, floor: floor)
        for playlist in playlists {
            let rows = try Row.fetchAll(
                db, sql: "SELECT id, syncId FROM playlistTracks WHERE playlistId = ? ORDER BY position, id", arguments: [playlist]
            )
            order.rows[playlist] = rows.map { ($0["id"], $0["syncId"]) }
            for row in rows { order.playlistOf[row["id"]] = playlist }
        }
        return order
    }

    private static func occurrenceNumbers(_ db: Database, _ playlists: Set<Int64>) throws -> [Int64: Int] {
        var numbers: [Int64: Int] = [:]
        for playlist in playlists {
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT pt.id, k.songKey FROM playlistTracks pt
                    JOIN tracks t ON t.fileURL = pt.trackFileURL JOIN sync_song_keys k ON k.trackId = t.id
                    WHERE pt.playlistId = ? ORDER BY pt.position, pt.id
                    """,
                arguments: [playlist]
            )
            var seen: [String: Int] = [:]
            for row in rows {
                let key: String = row["songKey"]
                numbers[row["id"]] = seen[key, default: 0]
                seen[key, default: 0] += 1
            }
        }
        return numbers
    }

    private static func importLoves(_ db: Database, nowMs: Int64) throws -> (report: ServerSyncImportReport, consumed: Bool) {
        var report = ServerSyncImportReport()
        let cursor = try SyncMeta.int(db, loveCursor) ?? 0
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT t.id, t.fileURL, t.title, t.artist, t.albumTitle, t.duration, t.audioFingerprint,
                       t.musicBrainzID, k.songKey
                FROM tracks t JOIN sync_song_keys k ON k.trackId = t.id
                WHERE t.loved = 1 AND t.id > ? ORDER BY t.id LIMIT ?
                """,
            arguments: [cursor, loveChunk]
        )
        guard let last = rows.last else { return (report, false) }
        var seen = Set<String>()
        var batch: [NewMutation] = []
        for row in rows {
            guard let song = songRef(row, fileURL: row["fileURL"]), seen.insert(song.songKey).inserted else { continue }
            let args: ServerJSON = ["songKey": .string(song.songKey), "ref": try ServerCoreBridge.json(song), "loved": true]
            batch.append(NewMutation("love.set", args, touches: [SyncPending.loveKey(song.songKey)], stamp: floorStamp))
            report.loves += 1
        }
        try SyncPending.appendAll(db, batch, nowMs: nowMs)
        try SyncMeta.setInt(db, loveCursor, last["id"])
        return (report, true)
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
        let batches = try SyncListens.listenDocuments(plays).chunked(into: SyncListens.batchSize)
        try SyncPending.appendAll(db, batches.map(SyncListens.recordMutation), nowMs: nowMs)
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
        let known = try db.cachedStatement(sql: "SELECT EXISTS (SELECT 1 FROM scrobbles WHERE eventId = ?)")
        for (item, id) in zip(valid, ids) {
            let exists = try Bool.fetchOne(known, arguments: [id]) ?? false
            if exists || !taken.insert(id).inserted {
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
