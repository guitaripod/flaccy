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

    /// Stores a pulled change as the base of its entity. A value this build cannot read is skipped.
    static func put(_ db: Database, _ change: ServerChange) throws -> Stored? {
        guard let shape = Shape(change), let text = change.value.text else { return nil }
        let insert = try db.cachedStatement(sql: """
            INSERT INTO sync_base (kind, id, parent, value_json, deleted) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(kind, id) DO UPDATE SET
                parent = excluded.parent, value_json = excluded.value_json, deleted = excluded.deleted
            """)
        try insert.execute(arguments: [change.kind.wireName, change.id, shape.parent, text, change.deleted])
        return Stored(foldKey: shape.foldKey, scalarKey: shape.scalarKey)
    }

    /// What a change must carry to be stored and folded later, checked on the parsed document without decoding it a second time.
    private struct Shape {
        var parent: String?
        var foldKey: String?
        var scalarKey: String?

        init?(_ change: ServerChange) {
            let value = change.value
            switch change.kind {
            case .playlist:
                guard value["id"]?.string == change.id, value["name"]?.string != nil, value["owner"]?.string != nil,
                      value["alive"]?.bool != nil, value["stamps"] != nil
                else { return nil }
                foldKey = SyncPending.playlistKey(change.id)
            case .playlistEntry:
                guard value["id"]?.string == change.id, let playlist = value["playlist"]?.string, value["pos"]?.string != nil,
                      value["alive"]?.bool != nil, value["stamps"] != nil, Self.isSongRef(value["ref"])
                else { return nil }
                parent = playlist
                foldKey = SyncPending.playlistKey(playlist)
            case .love:
                guard value["songKey"]?.string == change.id, value["loved"]?.bool != nil, value["stamp"]?.int != nil,
                      Self.isSongRef(value["ref"])
                else { return nil }
                foldKey = SyncPending.loveKey(change.id)
            case .scalar:
                guard value["key"]?.string == change.id, value["deleted"]?.bool != nil, value["stamp"]?.int != nil else { return nil }
                foldKey = SyncPending.scalarKey(change.id)
                scalarKey = change.id
            case .session:
                guard value["device"]?.string == change.id, value["session"] != nil else { return nil }
            case .rating:
                break
            case .listen, .unknown:
                return nil
            }
        }

        private static func isSongRef(_ value: ServerJSON?) -> Bool {
            guard let value else { return false }
            return value["songKey"]?.string != nil && value["title"]?.string != nil && value["artist"]?.string != nil
        }
    }

    static func doc(_ db: Database, playlistID: String) throws -> CorePlaylistDoc? {
        let fetchHead = try db.cachedStatement(sql: "SELECT value_json FROM sync_base WHERE kind = ? AND id = ?")
        guard let text = try String.fetchOne(fetchHead, arguments: [playlist, playlistID]) else { return nil }
        let head = try ServerCoreBridge.decode(CorePlaylist.self, from: text)
        let fetchEntries = try db.cachedStatement(sql: "SELECT value_json FROM sync_base WHERE kind = ? AND parent = ?")
        let entries = try String.fetchAll(fetchEntries, arguments: [entry, playlistID])
            .map { try ServerCoreBridge.decode(CoreEntry.self, from: $0) }
        return CorePlaylistDoc(playlist: head, entries: entries)
    }

    static func love(_ db: Database, songKey: String) throws -> CoreLove? {
        try value(db, kind: love, id: songKey)
    }

    static func scalar(_ db: Database, key: String) throws -> CoreScalar? {
        try value(db, kind: scalar, id: key)
    }

    private static func value<T: Decodable>(_ db: Database, kind: String, id: String) throws -> T? {
        let fetch = try db.cachedStatement(sql: "SELECT value_json FROM sync_base WHERE kind = ? AND id = ?")
        guard let text = try String.fetchOne(fetch, arguments: [kind, id]) else { return nil }
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
