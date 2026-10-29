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
    static let applyChunkRows = 400
    static let refreshWeight = 120
    static let listensSliceRows = 500

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

    /// Starts syncing with a server: stores its identity and, when the account may write, marks what the library holds as waiting to
    /// be imported and imports the first playlists, all in one short transaction. Replaces any earlier server.
    func attach(_ enrollment: ServerSyncEnrollment, role: ServerRole) throws -> ServerSyncImportReport {
        let wasConfigured = gate.isConfigured
        let wasRecording = gate.isRecording
        let report: ServerSyncImportReport
        do {
            report = try database.dbQueue.write { db in
                try SyncMeta.clearAll(db)
                try SyncMeta.set(db, SyncMeta.serverURL, enrollment.serverURL)
                try SyncMeta.set(db, SyncMeta.serverName, enrollment.serverName)
                try SyncMeta.set(db, SyncMeta.user, enrollment.user)
                try SyncMeta.set(db, SyncMeta.instance, enrollment.instance)
                try SyncMeta.set(db, SyncMeta.incarnation, enrollment.incarnation)
                try SyncMeta.set(db, SyncMeta.role, role.rawValue)
                try SyncMeta.setInt(db, SyncMeta.cursor, 0)
                try SyncMeta.setInt(db, SyncMeta.nextMutationId, 1)
                try SyncMeta.observeServerTime(db, serverTimeMs: enrollment.serverTimeMs, localNowMs: nowMs)
                try SyncMeta.set(db, SyncMeta.device, enrollment.device)
                gate.setConfigured(true)
                guard role.canWrite else { return ServerSyncImportReport() }
                return try startRecording(db)
            }
        } catch {
            gate.setConfigured(wasConfigured)
            gate.setRecording(wasRecording)
            throw error
        }
        gate.announceRecorded()
        return report
    }

    private func startRecording(_ db: Database) throws -> ServerSyncImportReport {
        let report = try SyncImport.begin(db, nowMs: nowMs)
        try SyncMeta.set(db, SyncMeta.recording, "1")
        gate.setRecording(true)
        return report
    }

    /// An account that could only listen was given access: the library is marked for import and writes start being queued.
    func beginRecording() throws -> ServerSyncImportReport {
        let wasRecording = gate.isRecording
        do {
            return try database.dbQueue.write { try startRecording($0) }
        } catch {
            gate.setRecording(wasRecording)
            throw error
        }
    }

    var isRecording: Bool { gate.isRecording }

    func role() throws -> ServerRole? {
        try meta(SyncMeta.role).flatMap(ServerRole.init(rawValue:))
    }

    func setRole(_ role: ServerRole) throws {
        try setMeta(SyncMeta.role, role.rawValue)
    }

    /// One bounded step of the structure import, committed on its own. Answers what it queued and true once none is left.
    func importStructureStep() throws -> (report: ServerSyncImportReport, done: Bool) {
        try autoreleasepool {
            try database.dbQueue.write { try SyncImport.step($0, nowMs: nowMs) }
        }
    }

    func isStructureImported() throws -> Bool {
        try database.dbQueue.read { try SyncImport.isStructureDone($0) }
    }

    /// Stops syncing: forgets the server, the base and the queue. Playlists, loves and plays stay as they are.
    func detach() throws {
        try database.dbQueue.write { db in
            try SyncMeta.clearAll(db)
            gate.setConfigured(false)
            gate.setRecording(false)
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
    func blobs(for mutations: [ServerMutation]) throws -> [(hash: String, data: Data?)] {
        var hashes = mutations.filter { $0.name == "playlist.setCover" }.compactMap { $0.args["blob"]?.string }
        hashes.append(contentsOf: mutations.flatMap(ReseedCovers.hashes(in:)))
        var seen = Set<String>()
        return try database.dbQueue.read { db in
            try hashes.filter { seen.insert($0).inserted }.map { hash in
                (hash, try Data.fetchOne(db, sql: "SELECT data FROM sync_blobs WHERE hash = ?", arguments: [hash]))
            }
        }
    }

    /// The server refused reseed mutations because of a cover. They stay queued, unacknowledged and not failed, and the queue moves
    /// to a new instance so they are sent again under ids the server has not spent. The first time the covers are expected to
    /// have been uploaded again; the second time they are taken out so the rest of the base still reaches the server.
    func keepRefusedReseeds(instance: String, response: ServerPushResponse, ids: Set<Int64>, removeCovers: Bool) throws {
        try database.dbQueue.write { db in
            try SyncMeta.observeServerTime(db, serverTimeMs: response.serverTimeMs, localNowMs: nowMs)
            guard let link = try SyncMeta.link(db), link.instance == instance else { return }
            _ = try SyncPending.markResults(db, response.results.filter { !ids.contains($0.id) })
            if removeCovers {
                for id in ids {
                    guard let text = try String.fetchOne(db, sql: "SELECT args_json FROM sync_pending WHERE mutation_id = ?", arguments: [id]),
                          let args = ServerJSON(text: text)
                    else { continue }
                    let mutation = ServerMutation(id: id, name: SyncPending.reseed, stamp: 0, args: args)
                    for hash in ReseedCovers.hashes(in: mutation) {
                        try db.execute(sql: "DELETE FROM sync_blobs WHERE hash = ?", arguments: [hash])
                    }
                    guard let stripped = ReseedCovers.removing(nil, from: mutation).args.text else { continue }
                    try db.execute(sql: "UPDATE sync_pending SET args_json = ? WHERE mutation_id = ?", arguments: [stripped, id])
                }
                try SyncMeta.remove(db, SyncMeta.reseedCoverRetry)
            } else {
                try SyncMeta.set(db, SyncMeta.reseedCoverRetry, "1")
            }
            try SyncReset.afterInstanceConflict(db, nowMs: nowMs)
        }
    }

    func hasRetriedReseedCovers() throws -> Bool {
        try meta(SyncMeta.reseedCoverRetry) != nil
    }

    /// A push succeeded: every answered mutation is acknowledged and refused ones drop out of the visible state.
    /// Nothing is retired; only a pull does that. With `keepForbidden`, writes the server refused because the account lost its right
    /// to write stay queued, unacknowledged and not failed, and the queue moves to a new instance so they get ids the server has
    /// not spent.
    func onPushResponse(
        instance: String, response: ServerPushResponse, localNowMs: Int64, keepForbidden: Bool = false
    ) throws -> MaterializeOutcome {
        try database.dbQueue.write { db in
            try SyncMeta.observeServerTime(db, serverTimeMs: response.serverTimeMs, localNowMs: localNowMs)
            guard let link = try SyncMeta.link(db), link.instance == instance else { return MaterializeOutcome() }
            let results = keepForbidden ? response.results.filter { $0.code != "forbidden" } : response.results
            var dirty = SyncDirty()
            for key in try SyncPending.markResults(db, results) { dirty.add(foldKey: key) }
            if keepForbidden { try SyncReset.afterInstanceConflict(db, nowMs: nowMs) }
            return try refreshAll(db, dirty)
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
        var dirty = SyncDirty()
        for chunk in response.changes.chunked(into: Self.applyChunkRows) {
            try autoreleasepool {
                try database.dbQueue.write { db in
                    for change in chunk {
                        if let stored = try SyncBase.put(db, change), let key = stored.foldKey { dirty.add(foldKey: key) }
                    }
                }
            }
        }
        var outcome = try materialize(dirty)
        let retired = try database.dbQueue.write { db -> SyncDirty in
            try finishPage(db, response: response)
        }
        outcome.merge(try materialize(retired))
        return .applied(more: response.more, outcome: outcome)
    }

    private func finishPage(_ db: Database, response: ServerPullResponse) throws -> SyncDirty {
        var dirty = SyncDirty()
        let cursor = response.more ? (response.changes.last?.seq ?? response.head) : response.head
        try SyncMeta.setInt(db, SyncMeta.cursor, cursor)
        try SyncMeta.set(db, SyncMeta.incarnation, response.incarnation)
        guard !response.more else { return dirty }
        for key in try SyncPending.retire(db, confirmed: response.lastMutationId) where key.hasPrefix("playlist:") {
            dirty.add(foldKey: key)
        }
        try SyncMeta.setInt(db, SyncMeta.lastSynced, nowMs)
        return dirty
    }

    /// Recomputes dirty entities into the app tables in transactions of bounded weight, so no write waits long behind them.
    func materialize(_ dirty: SyncDirty) throws -> MaterializeOutcome {
        var outcome = MaterializeOutcome()
        guard !dirty.isEmpty else { return outcome }
        for batch in try weighed(dirty) {
            let part = try autoreleasepool {
                try database.dbQueue.write { try refresh($0, batch) }
            }
            outcome.merge(part)
        }
        return outcome
    }

    private func weighed(_ dirty: SyncDirty) throws -> [SyncDirty] {
        let sizes: [String: Int] = try database.dbQueue.read { db in
            var sizes: [String: Int] = [:]
            for id in dirty.playlists {
                sizes[id] = try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM sync_base WHERE kind = 'playlist_entry' AND parent = ?", arguments: [id]
                ) ?? 0
            }
            return sizes
        }
        var batches: [SyncDirty] = []
        var current = SyncDirty()
        var weight = 0
        func close() {
            if !current.isEmpty { batches.append(current) }
            current = SyncDirty()
            weight = 0
        }
        for id in dirty.playlists.sorted() {
            current.playlists.insert(id)
            weight += 1 + (sizes[id] ?? 0) / 2
            if weight >= Self.refreshWeight { close() }
        }
        for key in dirty.loves.sorted() {
            current.loves.insert(key)
            weight += 1
            if weight >= Self.refreshWeight { close() }
        }
        for key in dirty.scalars.sorted() {
            current.scalars.insert(key)
            weight += 1
            if weight >= Self.refreshWeight { close() }
        }
        close()
        return batches
    }

    private func refresh(_ db: Database, _ dirty: SyncDirty) throws -> MaterializeOutcome {
        guard let caller = try SyncMaterializer.caller(db) else { return MaterializeOutcome() }
        return try SyncMaterializer.refresh(db, dirty: dirty, caller: caller)
    }

    private func refreshAll(_ db: Database, _ dirty: SyncDirty) throws -> MaterializeOutcome {
        try refresh(db, dirty)
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
        var memo = ListenKeyMemo()
        var written = 0
        let slices = page.listens.chunked(into: Self.listensSliceRows)
        for slice in slices.dropLast() {
            written += try autoreleasepool {
                try database.dbQueue.write { try SyncListens.store($0, slice, memo: &memo) }
            }
        }
        written += try autoreleasepool {
            try database.dbQueue.write { try SyncListens.apply($0, page: page, memo: &memo, rows: slices.last ?? []) }
        }
        return written
    }

    /// Queues the next chunk of the person's earlier plays as migrated listens. Answers true once none are left.
    func importListensChunk() throws -> (queued: Int, done: Bool) {
        let result = try autoreleasepool {
            try database.dbQueue.write { try SyncImport.importListens($0, nowMs: nowMs) }
        }
        if result.queued > 0 { gate.announceRecorded() }
        return result
    }

    func refreshSongKeyIndex() throws {
        try SyncSongRefs.refreshIndex(database)
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
