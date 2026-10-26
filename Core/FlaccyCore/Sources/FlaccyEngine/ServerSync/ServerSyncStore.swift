import FlaccyCore
import Foundation
import GRDB

/// What enrolling returned, as the store keeps it.
struct ServerSyncEnrollment: Sendable {
    var serverURL: String
    var serverName: String
    var device: String
    var user: String
    var incarnation: String
    var instance: String
    var serverTimeMs: Int64
}

/// A refused push and what the engine does about it.
enum PushFailure: Sendable, Equatable {
    case instanceConflict
    case mutationGap(have: Int64)
    case clockBehind
}

enum PushRecovery: Sendable, Equatable {
    case resend
    case reset
    case wait
}

/// The pull the engine makes next.
struct PullRequestInfo: Sendable, Equatable {
    var since: Int64
    var limit: Int
    var instance: String
    var incarnation: String?
}

enum PullOutcome: Sendable {
    case applied(more: Bool, outcome: MaterializeOutcome)
    case stale
    case reset
}

/// The sync state machine over the library database. It holds no connection to the server: the engine feeds it responses and asks it
/// what to send next, and everything durable lives in the database, so a crash at any point resumes from what was committed.
final class ServerSyncStore: Sendable {

    static let pushMaxMutations = 500
    static let pushMaxBytes = 900_000
    static let pullLimit = 5_000
    static let applyChunkRows = 5_000

    let database: DatabaseManager

    init(database: DatabaseManager) {
        self.database = database
    }

    private var gate: ServerSyncGate { database.serverSyncGate }
    private var nowMs: Int64 { gate.nowMs }

    func link() throws -> ServerSyncLink? {
        try database.dbQueue.read { try SyncMeta.link($0) }
    }

    func isConfigured() -> Bool {
        gate.isConfigured
    }

    func meta(_ key: String) throws -> String? {
        try database.dbQueue.read { try SyncMeta.get($0, key) }
    }

    func setMeta(_ key: String, _ value: String?) throws {
        try database.dbQueue.write { db in
            if let value { try SyncMeta.set(db, key, value) } else { try SyncMeta.remove(db, key) }
        }
    }

    /// Starts syncing with a server: stores its identity, then queues the local playlists, loves and covers, all in one
    /// transaction. Replaces any earlier server.
    func attach(_ enrollment: ServerSyncEnrollment) throws -> ServerSyncImportReport {
        let wasConfigured = gate.isConfigured
        let report: ServerSyncImportReport
        do {
            report = try database.dbQueue.write { db in
                try SyncMeta.clearAll(db)
                try SyncMeta.set(db, SyncMeta.serverURL, enrollment.serverURL)
                try SyncMeta.set(db, SyncMeta.serverName, enrollment.serverName)
                try SyncMeta.set(db, SyncMeta.user, enrollment.user)
                try SyncMeta.set(db, SyncMeta.instance, enrollment.instance)
                try SyncMeta.set(db, SyncMeta.incarnation, enrollment.incarnation)
                try SyncMeta.setInt(db, SyncMeta.cursor, 0)
                try SyncMeta.setInt(db, SyncMeta.nextMutationId, 1)
                try SyncMeta.observeServerTime(db, serverTimeMs: enrollment.serverTimeMs, localNowMs: nowMs)
                try SyncMeta.set(db, SyncMeta.device, enrollment.device)
                let report = try SyncImport.queueStructure(db, nowMs: nowMs)
                gate.setConfigured(true)
                return report
            }
        } catch {
            gate.setConfigured(wasConfigured)
            throw error
        }
        gate.announceRecorded()
        return report
    }

    /// Stops syncing: forgets the server, the base and the queue. Playlists, loves and plays stay as they are.
    func detach() throws {
        try database.dbQueue.write { db in
            try SyncMeta.clearAll(db)
            gate.setConfigured(false)
        }
    }

    func nextPush() throws -> ServerPushRequest? {
        try database.dbQueue.write { db in
            guard let link = try SyncMeta.link(db) else { return nil }
            let mutations = try SyncPending.nextBatch(db, maxCount: Self.pushMaxMutations, maxBytes: Self.pushMaxBytes)
            guard !mutations.isEmpty else { return nil }
            return ServerPushRequest(device: link.device, instance: link.instance, mutations: mutations)
        }
    }

    /// The cover images the mutations of a push refer to, for upload before the push.
    func blobs(for mutations: [ServerMutation]) throws -> [(hash: String, data: Data)] {
        let hashes = mutations.filter { $0.name == "playlist.setCover" }.compactMap { $0.args["blob"]?.string }
        return try database.dbQueue.read { db in
            try hashes.compactMap { hash in
                try Data.fetchOne(db, sql: "SELECT data FROM sync_blobs WHERE hash = ?", arguments: [hash]).map { (hash, $0) }
            }
        }
    }

    /// A push succeeded: every answered mutation is acknowledged and refused ones drop out of the visible state.
    /// Nothing is retired; only a pull does that.
    func onPushResponse(instance: String, response: ServerPushResponse, localNowMs: Int64) throws -> MaterializeOutcome {
        try database.dbQueue.write { db in
            try SyncMeta.observeServerTime(db, serverTimeMs: response.serverTimeMs, localNowMs: localNowMs)
            guard let link = try SyncMeta.link(db), link.instance == instance else { return MaterializeOutcome() }
            var dirty = SyncDirty()
            for key in try SyncPending.markResults(db, response.results) { dirty.add(foldKey: key) }
            return try refresh(db, dirty)
        }
    }

    func onPushFailure(instance: String, failure: PushFailure) throws -> PushRecovery {
        try database.dbQueue.write { db in
            guard let link = try SyncMeta.link(db) else { throw ServerSyncStoreError.notConfigured }
            guard link.instance == instance else { return .resend }
            switch failure {
            case .clockBehind:
                return .wait
            case .instanceConflict:
                try SyncReset.afterInstanceConflict(db, nowMs: nowMs)
                return .resend
            case .mutationGap(let have):
                let retiredAhead = (try SyncPending.lowestId(db)).map { $0 > have + 1 } ?? false
                if retiredAhead {
                    try SyncReset.afterRestore(db, incarnation: nil, nowMs: nowMs)
                    return .reset
                }
                try SyncPending.unackAfter(db, have: have)
                return .resend
            }
        }
    }

    func pullRequest() throws -> PullRequestInfo {
        try database.dbQueue.read { db in
            guard let link = try SyncMeta.link(db) else { throw ServerSyncStoreError.notConfigured }
            return PullRequestInfo(
                since: try SyncMeta.cursorValue(db), limit: Self.pullLimit, instance: link.instance, incarnation: link.incarnation
            )
        }
    }

    /// A pull page arrived. A page for a request the engine has moved past is ignored, a new incarnation resets, otherwise the
    /// changes land in the base and the app tables follow, and a final page retires the mutations the server has applied.
    func onPullPage(request: PullRequestInfo, response: ServerPullResponse, localNowMs: Int64) throws -> PullOutcome {
        try SyncSongRefs.refreshIndex(database)
        let verdict = try database.dbQueue.write { db -> PullOutcome? in
            try SyncMeta.observeServerTime(db, serverTimeMs: response.serverTimeMs, localNowMs: localNowMs)
            guard let link = try SyncMeta.link(db) else { throw ServerSyncStoreError.notConfigured }
            guard request.instance == link.instance, request.since == (try SyncMeta.cursorValue(db)) else { return .stale }
            if let known = link.incarnation, known != response.incarnation {
                try SyncReset.afterRestore(db, incarnation: response.incarnation, nowMs: nowMs)
                return .reset
            }
            return nil
        }
        if let verdict { return verdict }
        var outcome = MaterializeOutcome()
        let chunks = response.changes.chunked(into: Self.applyChunkRows)
        let pages = chunks.isEmpty ? [[]] : chunks
        for (index, chunk) in pages.enumerated() {
            let last = index == pages.count - 1
            let part = try database.dbQueue.write { db -> MaterializeOutcome in
                var dirty = SyncDirty()
                for change in chunk {
                    if let stored = try SyncBase.put(db, change), let key = stored.foldKey { dirty.add(foldKey: key) }
                }
                if last { try finishPage(db, response: response, dirty: &dirty) }
                return try refresh(db, dirty)
            }
            outcome.merge(part)
        }
        return .applied(more: response.more, outcome: outcome)
    }

    private func finishPage(_ db: Database, response: ServerPullResponse, dirty: inout SyncDirty) throws {
        let cursor = response.more ? (response.changes.last?.seq ?? response.head) : response.head
        try SyncMeta.setInt(db, SyncMeta.cursor, cursor)
        try SyncMeta.set(db, SyncMeta.incarnation, response.incarnation)
        guard !response.more else { return }
        for key in try SyncPending.retire(db, confirmed: response.lastMutationId) { dirty.add(foldKey: key) }
        try SyncMeta.setInt(db, SyncMeta.lastSynced, nowMs)
    }

    private func refresh(_ db: Database, _ dirty: SyncDirty) throws -> MaterializeOutcome {
        guard let caller = try SyncMaterializer.caller(db) else { return MaterializeOutcome() }
        return try SyncMaterializer.refresh(db, dirty: dirty, caller: caller)
    }

    /// A pull was refused because its cursor is ahead of the server's log.
    func onCookieAhead(request: PullRequestInfo) throws -> PullOutcome {
        try database.dbQueue.write { db in
            guard let link = try SyncMeta.link(db) else { throw ServerSyncStoreError.notConfigured }
            guard request.instance == link.instance, request.since == (try SyncMeta.cursorValue(db)) else { return .stale }
            try SyncReset.afterRestore(db, incarnation: nil, nowMs: nowMs)
            return .reset
        }
    }

    /// Any call answered `409 incarnation_changed`: the state is another server's. Resets onto `incarnation`.
    func onIncarnationChanged(_ incarnation: String) throws {
        try database.dbQueue.write { try SyncReset.afterRestore($0, incarnation: incarnation, nowMs: nowMs) }
    }

    /// A listens call was refused because its position is ahead of the server's log.
    func onListensCookieAhead() throws {
        try database.dbQueue.write { try SyncReset.afterRestore($0, incarnation: nil, nowMs: nowMs) }
    }

    func onInstanceConflict() throws {
        try database.dbQueue.write { try SyncReset.afterInstanceConflict($0, nowMs: nowMs) }
    }

    func listensRequest() throws -> ListensRequest {
        try database.dbQueue.read { try SyncListens.nextRequest($0) }
    }

    func listensBackfilled() throws -> Bool {
        try database.dbQueue.read { try SyncListens.backfillDone($0) }
    }

    func onListensPage(_ page: ServerListensPage) throws -> Int {
        try database.dbQueue.write { db in
            var memo = ListenKeyMemo()
            return try SyncListens.apply(db, page: page, memo: &memo)
        }
    }

    /// Queues the next chunk of the person's earlier plays as migrated listens. Answers true once none are left.
    func importListensChunk() throws -> Bool {
        let (queued, done) = try database.dbQueue.write { try SyncImport.importListens($0, nowMs: nowMs) }
        if queued > 0 { gate.announceRecorded() }
        return done
    }

    func hasImportedListens() throws -> Bool {
        try meta(SyncMeta.imported) != nil
    }

    func pendingCount() throws -> Int {
        try database.dbQueue.read { try SyncPending.count($0) }
    }

    func unsentCount() throws -> Int {
        try database.dbQueue.read { try SyncPending.countUnacked($0) }
    }

    func lastSyncedAt() throws -> Int64? {
        try database.dbQueue.read { try SyncMeta.int($0, SyncMeta.lastSynced) }
    }

    func resolveGhosts() throws -> MaterializeOutcome {
        try SyncSongRefs.refreshIndex(database)
        return try database.dbQueue.write { try SyncMaterializer.resolveGhosts($0) }
    }

    /// The covers the base names for playlists that exist here, that this device holds under another hash or not at all, leaving
    /// out playlists with a cover write still waiting to be sent.
    func missingCovers() throws -> [ServerCoverNeed] {
        try database.dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT b.id AS syncId, json_extract(b.value_json, '$.coverBlob') AS blob, p.customCoverData AS cover
                    FROM sync_base b JOIN playlists p ON p.syncId = b.id
                    WHERE b.kind = 'playlist' AND json_extract(b.value_json, '$.coverBlob') IS NOT NULL
                      AND json_extract(b.value_json, '$.alive') = 1
                      AND NOT EXISTS (
                          SELECT 1 FROM sync_pending q
                          WHERE q.failed = 0 AND q.name IN ('playlist.setCover', 'playlist.clearCover')
                            AND q.touches_json LIKE '%"playlist:' || b.id || '"%')
                    """
            )
            return rows.compactMap { row in
                let blob: String = row["blob"]
                let cover: Data? = row["cover"]
                if let cover, SyncMaterializer.hexDigest(cover) == blob { return nil }
                return ServerCoverNeed(playlistSyncID: row["syncId"], hash: blob)
            }
        }
    }

    func applyCover(_ need: ServerCoverNeed, data: Data) throws -> Bool {
        try database.dbQueue.write {
            try SyncMaterializer.applyCover($0, playlistSyncID: need.playlistSyncID, hash: need.hash, data: data)
        }
    }
}
