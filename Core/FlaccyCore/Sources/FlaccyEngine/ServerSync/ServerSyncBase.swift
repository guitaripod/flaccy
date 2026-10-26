import FlaccyCore
import Foundation
import GRDB

/// The server's state as the last pull left it (`sync_base`): every entity's full value, before the local pending writes fold over it.
enum SyncBase {

    static let playlist = "playlist"
    static let entry = "playlist_entry"
    static let love = "love"
    static let scalar = "scalar"

    /// What storing a change made dirty, as the fold key of the entity it belongs to.
    struct Stored: Sendable {
        var foldKey: String?
        var scalarKey: String?
    }

    /// Stores a pulled change as the base of its entity. A value this build cannot decode is skipped.
    static func put(_ db: Database, _ change: ServerChange) throws -> Stored? {
        guard let decoded = ServerEntityValue(kind: change.kind, value: change.value),
              let text = change.value.text
        else { return nil }
        let kind = change.kind.wireName
        var parent: String?
        var stored = Stored()
        switch decoded {
        case .playlist(let value):
            stored.foldKey = SyncPending.playlistKey(value.id)
        case .entry(let value):
            parent = value.playlist
            stored.foldKey = SyncPending.playlistKey(value.playlist)
        case .love(let value):
            stored.foldKey = SyncPending.loveKey(value.songKey)
        case .scalar(let value):
            stored.foldKey = SyncPending.scalarKey(value.key)
            stored.scalarKey = value.key
        case .session, .rating:
            break
        case .listen:
            return nil
        }
        try db.execute(
            sql: """
                INSERT INTO sync_base (kind, id, parent, value_json, deleted) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(kind, id) DO UPDATE SET
                    parent = excluded.parent, value_json = excluded.value_json, deleted = excluded.deleted
                """,
            arguments: [kind, change.id, parent, text, change.deleted]
        )
        return stored
    }

    static func doc(_ db: Database, playlistID: String) throws -> CorePlaylistDoc? {
        guard let text = try String.fetchOne(
            db, sql: "SELECT value_json FROM sync_base WHERE kind = ? AND id = ?", arguments: [playlist, playlistID]
        ) else { return nil }
        let head = try ServerCoreBridge.decode(CorePlaylist.self, from: text)
        let entries = try String.fetchAll(
            db, sql: "SELECT value_json FROM sync_base WHERE kind = ? AND parent = ?", arguments: [entry, playlistID]
        ).map { try ServerCoreBridge.decode(CoreEntry.self, from: $0) }
        return CorePlaylistDoc(playlist: head, entries: entries)
    }

    static func love(_ db: Database, songKey: String) throws -> CoreLove? {
        try value(db, kind: love, id: songKey)
    }

    static func scalar(_ db: Database, key: String) throws -> CoreScalar? {
        try value(db, kind: scalar, id: key)
    }

    private static func value<T: Decodable>(_ db: Database, kind: String, id: String) throws -> T? {
        guard let text = try String.fetchOne(
            db, sql: "SELECT value_json FROM sync_base WHERE kind = ? AND id = ?", arguments: [kind, id]
        ) else { return nil }
        return try ServerCoreBridge.decode(T.self, from: text)
    }

    static func ids(_ db: Database, kind: String) throws -> [String] {
        try String.fetchAll(db, sql: "SELECT id FROM sync_base WHERE kind = ?", arguments: [kind])
    }

    /// The entities a reseed carries: the person's own playlists with their entries, and every love, rating, scalar and session.
    static func reseedEntities(_ db: Database, user: String) throws -> [ServerJSON] {
        let rows = try Row.fetchAll(db, sql: "SELECT kind, id, value_json FROM sync_base ORDER BY kind, id")
        var owned = Set<String>()
        var kept: [(kind: String, id: String, value: ServerJSON)] = []
        for row in rows {
            let kind: String = row["kind"]
            let id: String = row["id"]
            let text: String = row["value_json"]
            guard let value = ServerJSON(text: text) else { continue }
            if kind == playlist {
                guard value["owner"]?.string == user else { continue }
                owned.insert(id)
            }
            kept.append((kind, id, value))
        }
        return kept
            .filter { item in
                item.kind != entry || (item.value["playlist"]?.string).map(owned.contains) == true
            }
            .map { ["kind": .string($0.kind), "id": .string($0.id), "value": $0.value] }
    }

    static func clear(_ db: Database) throws {
        try db.execute(sql: "DELETE FROM sync_base")
    }
}
