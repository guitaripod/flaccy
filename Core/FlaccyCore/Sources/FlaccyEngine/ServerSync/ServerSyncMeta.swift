import FlaccyCore
import Foundation
import GRDB

/// What this database knows about the server it syncs with.
struct ServerSyncLink: Sendable, Equatable {
    var device: String
    var user: String
    var instance: String
    var incarnation: String?
    var serverURL: String
    var serverName: String
}

/// The `sync_meta` key-value table and the counters that live in it. Every function runs inside the caller's transaction.
enum SyncMeta {

    static let device = "device"
    static let user = "user"
    static let instance = "instance"
    static let incarnation = "incarnation"
    static let cursor = "cursor"
    static let nextMutationId = "next_mutation_id"
    static let lastStamp = "last_stamp"
    static let serverOffset = "server_offset_ms"
    static let eventCounter = "event_counter"
    static let serverURL = "server_url"
    static let serverName = "server_name"
    static let imported = "imported"
    static let importCursor = "import_cursor"
    static let lastSynced = "last_synced_at"
    static let tracksSignature = "tracks_signature"
    static let listensPhase = "listens_phase"
    static let listensBefore = "listens_before"
    static let listensAfter = "listens_after"
    static let listensTailFrom = "listens_tail_from"
    static let paused = "paused"

    static func get(_ db: Database, _ key: String) throws -> String? {
        try String.fetchOne(db, sql: "SELECT value FROM sync_meta WHERE key = ?", arguments: [key])
    }

    static func set(_ db: Database, _ key: String, _ value: String) throws {
        try db.execute(
            sql: "INSERT INTO sync_meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            arguments: [key, value]
        )
    }

    static func remove(_ db: Database, _ key: String) throws {
        try db.execute(sql: "DELETE FROM sync_meta WHERE key = ?", arguments: [key])
    }

    static func int(_ db: Database, _ key: String) throws -> Int64? {
        try get(db, key).flatMap { Int64($0) }
    }

    static func setInt(_ db: Database, _ key: String, _ value: Int64) throws {
        try set(db, key, String(value))
    }

    static func isConfigured(_ db: Database) throws -> Bool {
        try get(db, device) != nil
    }

    static func link(_ db: Database) throws -> ServerSyncLink? {
        guard let device = try get(db, device) else { return nil }
        return ServerSyncLink(
            device: device,
            user: try get(db, user) ?? "",
            instance: try get(db, instance) ?? "",
            incarnation: try get(db, incarnation),
            serverURL: try get(db, serverURL) ?? "",
            serverName: try get(db, serverName) ?? ""
        )
    }

    static func cursorValue(_ db: Database) throws -> Int64 {
        try int(db, cursor) ?? 0
    }

    static func takeMutationId(_ db: Database) throws -> Int64 {
        let id = try int(db, nextMutationId) ?? 1
        try setInt(db, nextMutationId, id + 1)
        return id
    }

    static func nextStamp(_ db: Database, nowMs: Int64) throws -> Int64 {
        let last = try int(db, lastStamp) ?? 0
        let offset = try int(db, serverOffset) ?? 0
        let stamp = try ServerCoreBridge.nextStamp(last: last, offsetMs: offset, nowMs: nowMs)
        try setInt(db, lastStamp, stamp)
        return stamp
    }

    static func observeServerTime(_ db: Database, serverTimeMs: Int64, localNowMs: Int64) throws {
        try setInt(db, serverOffset, serverTimeMs &- localNowMs)
    }

    static func takeEventCounter(_ db: Database) throws -> UInt64 {
        let counter = try int(db, eventCounter) ?? 0
        try setInt(db, eventCounter, counter + 1)
        return UInt64(counter)
    }

    /// Forgets the server, the base and the queue. The sync ids of playlists and entries and the event ids of plays stay, so
    /// connecting again to the same server finds what is already there instead of creating it twice.
    static func clearAll(_ db: Database) throws {
        for table in ServerSyncSchema.tables {
            try db.execute(sql: "DELETE FROM \(table)")
        }
    }
}
