import FlaccyCore
import Foundation
import GRDB

/// Starting over against a server whose state was replaced, or that met this instance's ids with different arguments.
enum SyncReset {

    /// The server's state was replaced (a new incarnation, or a cookie ahead of its log). Builds a `state.reseed` of what the base
    /// holds and this person may write, drops the base, restarts at cursor 0 under a new instance, and renumbers the queue behind
    /// the reseed. Plays are queued again too: the server may have lost some.
    static func afterRestore(_ db: Database, incarnation: String?, nowMs: Int64) throws {
        guard let link = try SyncMeta.link(db) else { throw ServerSyncStoreError.notConfigured }
        let entities = try ReseedCovers.prepared(db, try SyncBase.reseedEntities(db, user: link.user))
        var leading = try reseedMutations(entities)
        leading.append(contentsOf: try SyncListens.requeueAll(db))
        try SyncBase.clear(db)
        try db.execute(sql: "DELETE FROM sync_ghosts")
        try SyncMeta.set(db, SyncMeta.instance, ServerSyncIDs.uuidV7(nowMs: nowMs))
        if let incarnation {
            try SyncMeta.set(db, SyncMeta.incarnation, incarnation)
        } else {
            try SyncMeta.remove(db, SyncMeta.incarnation)
        }
        try SyncMeta.setInt(db, SyncMeta.cursor, 0)
        try SyncListens.rewind(db)
        try SyncPending.renumber(db, leading: leading, nowMs: nowMs)
    }

    /// The server met this instance's ids with different arguments (a restored phone backup, a copied database). Moves the queue to a
    /// new instance and gives the plays it has not answered new ids, so they are neither taken for repeats of the server's own plays
    /// nor shadow them when they are read back. With `rereadListens`, those plays are read again.
    static func afterInstanceConflict(_ db: Database, nowMs: Int64, rereadListens: Bool = false) throws {
        let instance = ServerSyncIDs.uuidV7(nowMs: nowMs)
        try SyncMeta.set(db, SyncMeta.instance, instance)
        if let link = try SyncMeta.link(db) {
            try SyncPending.reassignUnacknowledgedListens(db) { old in
                let counter = try SyncMeta.takeEventCounter(db)
                let new = try ServerCoreBridge.eventIdRec(deviceId: link.device, instance: instance, counter: counter)
                try db.execute(sql: "UPDATE scrobbles SET eventId = ? WHERE eventId = ?", arguments: [new, old])
                return new
            }
        }
        if rereadListens { try SyncListens.rewind(db) }
        try SyncPending.renumber(db, leading: [], nowMs: nowMs)
    }

    /// The base as `state.reseed` mutations of the sizes the server accepts, in the order the core keeps: a playlist before its entries.
    static func reseedMutations(_ entities: [ServerJSON]) throws -> [NewMutation] {
        try ServerCoreBridge.chunkReseed(entities).map { chunk in
            NewMutation(SyncPending.reseed, ["entities": .array(chunk)], touches: SyncPending.reseedTouches(chunk))
        }
    }
}
