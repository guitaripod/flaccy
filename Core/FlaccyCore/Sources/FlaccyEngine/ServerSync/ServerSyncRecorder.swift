import CryptoKit
import FlaccyCore
import Foundation
import GRDB

/// Turns the app's own writes into queued mutations.
///
/// Every method runs inside the transaction that also makes the app-table change, so no visible change
/// exists without its mutation and the mutation id and stamp are allocated in the same commit.
/// `init` answers nil, at the cost of one flag read, while no Flaccy Server is configured.
final class ServerSyncRecorder {

    private static let entriesPerMutation = 200
    private static let maxCoverBytes = 2 * 1024 * 1024

    private let db: Database
    private let gate: ServerSyncGate
    private let link: ServerSyncLink
    private var announced = false

    init?(_ db: Database, gate: ServerSyncGate) throws {
        guard gate.isRecording, let link = try SyncMeta.link(db) else { return nil }
        self.db = db
        self.gate = gate
        self.link = link
    }

    func playlistCreated(localId: Int64, name: String) throws {
        let id = newID()
        try db.execute(sql: "UPDATE playlists SET syncId = ? WHERE id = ?", arguments: [id, localId])
        try queue("playlist.create", ["id": .string(id), "name": .string(name)], touches: [SyncPending.playlistKey(id)])
    }

    func playlistRenamed(localId: Int64, name: String) throws {
        guard let id = try playlistSyncID(localId) else { return }
        try queue("playlist.rename", ["id": .string(id), "name": .string(name)], touches: [SyncPending.playlistKey(id)])
    }

    func playlistDeleted(localId: Int64) throws {
        guard let id = try playlistSyncID(localId) else { return }
        try queue("playlist.delete", ["id": .string(id)], touches: [SyncPending.playlistKey(id)])
    }

    func coverSet(localId: Int64, data: Data) throws {
        guard let id = try playlistSyncID(localId) else { return }
        guard !data.isEmpty, data.count <= Self.maxCoverBytes else {
            return try coverCleared(localId: localId)
        }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try db.execute(sql: "INSERT OR IGNORE INTO sync_blobs (hash, data) VALUES (?, ?)", arguments: [hash, data])
        try queue("playlist.setCover", ["id": .string(id), "blob": .string(hash)], touches: [SyncPending.playlistKey(id)])
    }

    func coverCleared(localId: Int64) throws {
        guard let id = try playlistSyncID(localId) else { return }
        try queue("playlist.clearCover", ["id": .string(id)], touches: [SyncPending.playlistKey(id)])
    }

    func tracksAdded(playlistLocalId: Int64, rows: [(rowId: Int64, fileURL: String)]) throws {
        guard let playlist = try playlistSyncID(playlistLocalId) else { return }
        var entries: [ServerJSON] = []
        for row in rows {
            guard let song = try SyncSongRefs.ref(db, fileURL: row.fileURL) else { continue }
            let id = newID()
            try db.execute(sql: "UPDATE playlistTracks SET syncId = ? WHERE id = ?", arguments: [id, row.rowId])
            entries.append(["id": .string(id), "ref": try ServerCoreBridge.json(song)])
        }
        let touches = [SyncPending.playlistKey(playlist)]
        for chunk in entries.chunked(into: Self.entriesPerMutation) {
            if chunk.count == 1, let only = chunk.first, let id = only["id"], let ref = only["ref"] {
                try queue(
                    "entry.insert",
                    ["id": id, "playlist": .string(playlist), "ref": ref, "place": ["kind": "last"]],
                    touches: touches
                )
            } else {
                try queue(
                    "entry.insertMany",
                    ["playlist": .string(playlist), "entries": .array(chunk), "place": ["kind": "last"]],
                    touches: touches
                )
            }
        }
    }

    func trackRemoved(rowId: Int64) throws {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT t.syncId AS entry, p.syncId AS playlist FROM playlistTracks t
                JOIN playlists p ON p.id = t.playlistId WHERE t.id = ?
                """,
            arguments: [rowId]
        ), let entry: String = row["entry"], let playlist: String = row["playlist"] else { return }
        try queue("entry.remove", ["id": .string(entry)], touches: [SyncPending.playlistKey(playlist)])
    }

    /// What a playlist row had before it moved, so the move can be told from a write that left it where it was.
    struct MoveWitness {
        fileprivate var rowId: Int64
        fileprivate var playlistLocalId: Int64
        fileprivate var playlist: String
        fileprivate var entry: String
        fileprivate var formerPrevious: String?
    }

    func beginMove(rowId: Int64) throws -> MoveWitness? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT t.playlistId AS local, t.syncId AS entry, p.syncId AS playlist FROM playlistTracks t
                JOIN playlists p ON p.id = t.playlistId WHERE t.id = ?
                """,
            arguments: [rowId]
        ), let entry: String = row["entry"], let playlist: String = row["playlist"] else { return nil }
        let local: Int64 = row["local"]
        return MoveWitness(
            rowId: rowId, playlistLocalId: local, playlist: playlist, entry: entry,
            formerPrevious: try previousEntry(of: entry, inPlaylist: local)
        )
    }

    func endMove(_ witness: MoveWitness?) throws {
        guard let witness else { return }
        let previous = try previousEntry(of: witness.entry, inPlaylist: witness.playlistLocalId)
        guard previous != witness.formerPrevious else { return }
        let place: ServerJSON = previous.map { ["kind": "after", "id": .string($0)] } ?? ["kind": "first"]
        try queue(
            "entry.move", ["id": .string(witness.entry), "place": place],
            touches: [SyncPending.playlistKey(witness.playlist)]
        )
    }

    func loved(fileURL: String, loved: Bool) throws {
        guard let song = try SyncSongRefs.ref(db, fileURL: fileURL) else { return }
        try queue(
            "love.set",
            ["songKey": .string(song.songKey), "ref": try ServerCoreBridge.json(song), "loved": .bool(loved)],
            touches: [SyncPending.loveKey(song.songKey)]
        )
    }

    func played(rowId: Int64, title: String, artist: String, album: String, timestamp: Date, playedSeconds: Int) throws {
        let counter = try SyncMeta.takeEventCounter(db)
        let eventId = try ServerCoreBridge.eventIdRec(deviceId: link.device, instance: link.instance, counter: counter)
        try db.execute(sql: "UPDATE scrobbles SET eventId = ? WHERE id = ?", arguments: [eventId, rowId])
        let listen = ServerListenInput(
            eventId: eventId, ts: Int64(timestamp.timeIntervalSince1970), ref: try SyncSongRefs.ref(title: title, artist: artist, album: album),
            playedS: Int64(max(playedSeconds, 0)), recorded: true
        )
        try SyncPending.appendListen(db, try ServerCoreBridge.json(listen), nowMs: gate.nowMs)
        announce()
    }

    func lyricsOffset(title: String, artist: String, offsetMs: Int) throws {
        guard offsetMs >= 0 else { return }
        try scalar(key: ServerScalarRules.lyricsKey(songKey: SyncSongRefs.songKey(title: title, artist: artist)), value: .int(Int64(offsetMs)))
    }

    func scalar(key: String, value: ServerJSON) throws {
        guard ServerScalarRules.isValid(key: key, value: value) else { return }
        try queue("scalar.set", ["key": .string(key), "value": value], touches: [SyncPending.scalarKey(key)])
    }

    func scalarCleared(key: String) throws {
        guard ServerScalarRules.isValidKey(key) else { return }
        try queue("scalar.clear", ["key": .string(key)], touches: [SyncPending.scalarKey(key)])
    }

    private func queue(_ name: String, _ args: ServerJSON, touches: [String]) throws {
        try SyncPending.append(db, NewMutation(name, args, touches: touches), nowMs: gate.nowMs)
        announce()
    }

    private func announce() {
        guard !announced else { return }
        announced = true
        db.afterNextTransaction(onCommit: { [gate] _ in gate.announceRecorded() })
    }

    private func newID() -> String {
        ServerSyncIDs.uuidV7(nowMs: gate.nowMs)
    }

    private func playlistSyncID(_ localId: Int64) throws -> String? {
        if let known = try String.fetchOne(db, sql: "SELECT syncId FROM playlists WHERE id = ?", arguments: [localId]) {
            return known
        }
        return try SyncImport.ensurePlaylist(db, localID: localId, nowMs: gate.nowMs)
    }

    private func previousEntry(of entry: String, inPlaylist local: Int64) throws -> String? {
        let order = try String.fetchAll(
            db,
            sql: "SELECT syncId FROM playlistTracks WHERE playlistId = ? AND +syncId IS NOT NULL ORDER BY position, id",
            arguments: [local]
        )
        guard let index = order.firstIndex(of: entry), index > 0 else { return nil }
        return order[index - 1]
    }
}
