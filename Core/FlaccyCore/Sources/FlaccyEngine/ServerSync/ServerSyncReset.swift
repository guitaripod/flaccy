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

    /// The server met this instance's ids with different arguments (a restored phone backup, a copied database). Moves the queue to a new instance.
    static func afterInstanceConflict(_ db: Database, nowMs: Int64) throws {
        try SyncMeta.set(db, SyncMeta.instance, ServerSyncIDs.uuidV7(nowMs: nowMs))
        try SyncPending.renumber(db, leading: [], nowMs: nowMs)
    }

    /// The base as `state.reseed` mutations of the sizes the server accepts, in the order the core keeps: a playlist before its entries.
    static func reseedMutations(_ entities: [ServerJSON]) throws -> [NewMutation] {
        try ServerCoreBridge.chunkReseed(entities).map { chunk in
            NewMutation(SyncPending.reseed, ["entities": .array(chunk)], touches: SyncPending.reseedTouches(chunk))
        }
    }
}
