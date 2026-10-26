import FlaccyCore
import Foundation
import GRDB

/// Starting over against a server whose state was replaced, or that met this instance's ids with different arguments.
enum SyncReset {

    static let reseedEntitiesPerMutation = 1_000
    static let reseedBytesPerMutation = 400_000

    /// The server's state was replaced (a new incarnation, or a cookie ahead of its log). Builds a `state.reseed` of what the base
    /// holds and this person may write, drops the base, restarts at cursor 0 under a new instance, and renumbers the queue behind
    /// the reseed. Plays are queued again too: the server may have lost some.
    static func afterRestore(_ db: Database, incarnation: String?, nowMs: Int64) throws {
        guard let link = try SyncMeta.link(db) else { throw ServerSyncStoreError.notConfigured }
        var leading = reseedMutations(try SyncBase.reseedEntities(db, user: link.user))
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

    static func reseedMutations(_ entities: [ServerJSON]) -> [NewMutation] {
        var mutations: [NewMutation] = []
        var batch: [ServerJSON] = []
        var bytes = 0
        for entity in entities {
            bytes += entity.text?.utf8.count ?? 0
            batch.append(entity)
            if batch.count >= reseedEntitiesPerMutation || bytes >= reseedBytesPerMutation {
                mutations.append(reseedMutation(batch))
                batch = []
                bytes = 0
            }
        }
        if !batch.isEmpty { mutations.append(reseedMutation(batch)) }
        return mutations
    }

    private static func reseedMutation(_ entities: [ServerJSON]) -> NewMutation {
        NewMutation(SyncPending.reseed, ["entities": .array(entities)], touches: SyncPending.reseedTouches(entities))
    }
}
