import FlaccyCore
import Foundation
import GRDB

/// A mutation about to join the queue.
struct NewMutation: Sendable {
    var name: String
    var args: ServerJSON
    var touches: [String]
    var stamp: Int64?

    init(_ name: String, _ args: ServerJSON, touches: [String] = [], stamp: Int64? = nil) {
        self.name = name
        self.args = args
        self.touches = touches
        self.stamp = stamp
    }
}

/// A queued mutation as stored.
struct PendingRow: Sendable {
    var id: Int64
    var name: String
    var stamp: Int64
    var argsJSON: String
    var acked: Bool
    var failed: Bool
    var touches: [String]
}

/// The queue of local writes the server has not yet confirmed (`sync_pending`).
enum SyncPending {

    static let listenRecord = "listen.record"
    static let reseed = "state.reseed"
    static let listensPerCoalescedMutation = 200

    static func playlistKey(_ id: String) -> String { "playlist:\(id)" }
    static func loveKey(_ songKey: String) -> String { "love:\(songKey)" }
    static func scalarKey(_ key: String) -> String { "scalar:\(key)" }

    @discardableResult
    static func append(_ db: Database, _ new: NewMutation, nowMs: Int64) throws -> Int64 {
        let id = try SyncMeta.takeMutationId(db)
        let stamp = try new.stamp ?? SyncMeta.nextStamp(db, nowMs: nowMs)
        try insertRow(db, id: id, name: new.name, stamp: stamp, argsJSON: text(new.args), touches: new.touches)
        return id
    }

    private static func text(_ json: ServerJSON) throws -> String {
        guard let text = json.text else { throw ServerSyncStoreError.unencodable }
        return text
    }

    private static func insertRow(
        _ db: Database, id: Int64, name: String, stamp: Int64, argsJSON: String, touches: [String]
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO sync_pending (mutation_id, name, stamp, args_json, touches_json)
                VALUES (?, ?, ?, ?, ?)
                """,
            arguments: [id, name, stamp, argsJSON, try ServerCoreBridge.text(touches)]
        )
    }

    static func appendListen(_ db: Database, _ listen: ServerJSON, nowMs: Int64) throws {
        if let open = try openListenBatch(db), var listens = open.listens.array,
           listens.count < listensPerCoalescedMutation
        {
            listens.append(listen)
            let args: ServerJSON = ["listens": .array(listens)]
            try db.execute(
                sql: "UPDATE sync_pending SET args_json = ? WHERE mutation_id = ?",
                arguments: [try text(args), open.id]
            )
            return
        }
        try append(db, NewMutation(listenRecord, ["listens": [listen]]), nowMs: nowMs)
    }

    private static func openListenBatch(_ db: Database) throws -> (id: Int64, listens: ServerJSON)? {
        guard let row = try Row.fetchOne(
            db, sql: "SELECT mutation_id, name, sent, acked, args_json FROM sync_pending ORDER BY mutation_id DESC LIMIT 1"
        ) else { return nil }
        let name: String = row["name"]
        let sent: Int = row["sent"]
        let acked: Int = row["acked"]
        guard name == listenRecord, sent == 0, acked == 0 else { return nil }
        let argsJSON: String = row["args_json"]
        guard let listens = ServerJSON(text: argsJSON)?["listens"] else { return nil }
        return (row["mutation_id"], listens)
    }

    static func nextBatch(_ db: Database, maxCount: Int, maxBytes: Int) throws -> [ServerMutation] {
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT mutation_id, name, stamp, args_json FROM sync_pending WHERE acked = 0 ORDER BY mutation_id LIMIT ?",
            arguments: [maxCount]
        )
        var batch: [ServerMutation] = []
        var bytes = 0
        for row in rows {
            let argsJSON: String = row["args_json"]
            bytes += argsJSON.utf8.count
            if !batch.isEmpty, bytes > maxBytes { break }
            guard let args = ServerJSON(text: argsJSON) else { throw ServerSyncStoreError.unencodable }
            batch.append(ServerMutation(id: row["mutation_id"], name: row["name"], stamp: row["stamp"], args: args))
        }
        for mutation in batch {
            try db.execute(sql: "UPDATE sync_pending SET sent = 1 WHERE mutation_id = ?", arguments: [mutation.id])
        }
        return batch
    }

    static func markResults(_ db: Database, _ results: [ServerMutationResult]) throws -> [String] {
        var failedTouches: [String] = []
        for result in results {
            let refused = result.status.isRefusal
            if refused,
               let touches = try String.fetchOne(
                   db, sql: "SELECT touches_json FROM sync_pending WHERE mutation_id = ? AND failed = 0",
                   arguments: [result.id])
            {
                failedTouches.append(contentsOf: try ServerCoreBridge.decode([String].self, from: touches))
            }
            try db.execute(
                sql: "UPDATE sync_pending SET acked = 1, failed = ? WHERE mutation_id = ?",
                arguments: [refused, result.id]
            )
        }
        return failedTouches
    }

    static func retire(_ db: Database, confirmed: Int64) throws -> [String] {
        let texts = try String.fetchAll(
            db, sql: "SELECT touches_json FROM sync_pending WHERE acked = 1 AND mutation_id <= ?", arguments: [confirmed]
        )
        var touches: [String] = []
        for text in texts {
            touches.append(contentsOf: try ServerCoreBridge.decode([String].self, from: text))
        }
        try db.execute(sql: "DELETE FROM sync_pending WHERE acked = 1 AND mutation_id <= ?", arguments: [confirmed])
        return touches
    }

    static func count(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_pending") ?? 0
    }

    static func countUnacked(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_pending WHERE acked = 0") ?? 0
    }

    static func lowestId(_ db: Database) throws -> Int64? {
        try Int64.fetchOne(db, sql: "SELECT MIN(mutation_id) FROM sync_pending")
    }

    static func unackAfter(_ db: Database, have: Int64) throws {
        try db.execute(
            sql: "UPDATE sync_pending SET acked = 0, failed = 0, sent = 0 WHERE mutation_id > ?", arguments: [have]
        )
    }

    /// Gives every queued mutation a fresh id from 1 behind `leading`, forgetting what the server said about them.
    static func renumber(_ db: Database, leading: [NewMutation], nowMs: Int64) throws {
        let kept = try rows(db)
        try db.execute(sql: "DELETE FROM sync_pending")
        var next: Int64 = 1
        for lead in leading {
            let stamp = try lead.stamp ?? SyncMeta.nextStamp(db, nowMs: nowMs)
            try insertRow(db, id: next, name: lead.name, stamp: stamp, argsJSON: text(lead.args), touches: lead.touches)
            next += 1
        }
        for row in kept {
            try insertRow(db, id: next, name: row.name, stamp: row.stamp, argsJSON: row.argsJSON, touches: row.touches)
            next += 1
        }
        try SyncMeta.setInt(db, SyncMeta.nextMutationId, next)
    }

    static func rows(_ db: Database, excludingListens: Bool = false) throws -> [PendingRow] {
        let condition = excludingListens ? "WHERE name <> 'listen.record'" : ""
        return try Row.fetchAll(
            db,
            sql: "SELECT mutation_id, name, stamp, args_json, acked, failed, touches_json FROM sync_pending \(condition) ORDER BY mutation_id"
        ).map { row in
            let touches: String = row["touches_json"]
            return PendingRow(
                id: row["mutation_id"], name: row["name"], stamp: row["stamp"], argsJSON: row["args_json"],
                acked: (row["acked"] as Int) != 0, failed: (row["failed"] as Int) != 0,
                touches: (try? ServerCoreBridge.decode([String].self, from: touches)) ?? []
            )
        }
    }

    static func reseedKey(of entity: ServerJSON) -> String? {
        guard let id = entity["id"]?.string, let kind = entity["kind"]?.string else { return nil }
        switch kind {
        case "playlist": return playlistKey(id)
        case "playlist_entry":
            guard let playlist = entity["value"]?["playlist"]?.string else { return nil }
            return playlistKey(playlist)
        case "love": return loveKey(id)
        case "scalar": return scalarKey(id)
        default: return "\(kind):\(id)"
        }
    }

    static func reseedTouches(_ entities: [ServerJSON]) -> [String] {
        Array(Set(entities.compactMap(reseedKey(of:)))).sorted()
    }
}

enum ServerSyncStoreError: Error, Equatable {
    case unencodable
    case notConfigured
}

/// The queue indexed by the entity each mutation touches, so folding one entity reads only its own mutations.
struct SyncPendingIndex {

    private var byKey: [String: [CorePending]] = [:]

    static func load(_ db: Database) throws -> SyncPendingIndex {
        var index = SyncPendingIndex()
        for row in try SyncPending.rows(db, excludingListens: true) {
            if row.name == SyncPending.reseed {
                try index.addReseed(row)
                continue
            }
            let pending = try ServerCoreBridge.pending(
                id: row.id, name: row.name, stamp: row.stamp, argsJSON: row.argsJSON, failed: row.failed
            )
            for key in row.touches {
                index.byKey[key, default: []].append(pending)
            }
        }
        return index
    }

    func pending(for key: String) -> [CorePending] {
        byKey[key] ?? []
    }

    private mutating func addReseed(_ row: PendingRow) throws {
        guard let entities = ServerJSON(text: row.argsJSON)?["entities"]?.array else { return }
        var groups: [String: [ServerJSON]] = [:]
        for entity in entities {
            if let key = SyncPending.reseedKey(of: entity) { groups[key, default: []].append(entity) }
        }
        for (key, group) in groups {
            let args: ServerJSON = ["entities": .array(group)]
            guard let text = args.text else { continue }
            byKey[key, default: []].append(try ServerCoreBridge.pending(
                id: row.id, name: row.name, stamp: row.stamp, argsJSON: text, failed: row.failed
            ))
        }
    }
}
