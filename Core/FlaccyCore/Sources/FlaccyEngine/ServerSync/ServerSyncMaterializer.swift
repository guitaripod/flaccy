import FlaccyCore
import Foundation
import GRDB

/// Writes the visible state of each dirty entity (its base with the live pending mutations folded over it) into the app tables.
enum SyncMaterializer {

    static let lyricsPrefix = "lyr/"

    static func caller(_ db: Database) throws -> CoreCaller? {
        try SyncMeta.link(db).map { CoreCaller(user: $0.user, role: .member, device: $0.device) }
    }

    static func refresh(_ db: Database, dirty: SyncDirty, caller: CoreCaller) throws -> MaterializeOutcome {
        var outcome = MaterializeOutcome()
        guard !dirty.isEmpty else { return outcome }
        let index = SyncPendingLookup(db)
        let resolver = SyncSongResolver(db: db)
        for id in dirty.playlists.sorted() {
            let base = try SyncBase.doc(db, playlistID: id)
            let key = SyncPending.playlistKey(id)
            let visible = try index.hasPending(for: key)
                ? try ServerCoreBridge.rebasePlaylist(id: id, base: base, caller: caller, pending: index.pending(for: key))
                : base
            try syncPlaylist(db, id: id, visible: visible, resolver: resolver, outcome: &outcome)
        }
        for songKey in dirty.loves.sorted() {
            let base = try SyncBase.love(db, songKey: songKey)
            let key = SyncPending.loveKey(songKey)
            let visible = try index.hasPending(for: key)
                ? try ServerCoreBridge.rebaseLove(songKey: songKey, base: base, caller: caller, pending: index.pending(for: key))
                : base
            if let visible, try setLoved(db, songKey: songKey, loved: visible.loved) {
                outcome.changes.loves = true
            }
        }
        for key in dirty.scalars.sorted() {
            let base = try SyncBase.scalar(db, key: key)
            let pendingKey = SyncPending.scalarKey(key)
            let visible = try index.hasPending(for: pendingKey)
                ? try ServerCoreBridge.rebaseScalar(key: key, base: base, caller: caller, pending: index.pending(for: pendingKey))
                : base
            let value: ServerJSON? = try visible.flatMap { $0.deleted ? nil : try ServerCoreBridge.json($0.value) }
            if let songKey = key.hasPrefix(lyricsPrefix) ? String(key.dropFirst(lyricsPrefix.count)) : nil {
                if let offset = value?.int, try setLyricsOffset(db, songKey: songKey, offsetMs: offset) {
                    outcome.changes.lyricsOffsets = true
                }
            } else {
                outcome.scalars.append(ServerScalarChange(key: key, value: value))
                outcome.changes.scalarKeys.insert(key)
            }
        }
        return outcome
    }

    private static func setLoved(_ db: Database, songKey: String, loved: Bool) throws -> Bool {
        let update = try db.cachedStatement(sql: """
            UPDATE tracks SET loved = ?1 WHERE loved <> ?1
            AND id IN (SELECT trackId FROM sync_song_keys WHERE songKey = ?2)
            """)
        try update.execute(arguments: [loved, songKey])
        return db.changesCount > 0
    }

    private static func setLyricsOffset(_ db: Database, songKey: String, offsetMs: Int64) throws -> Bool {
        try db.execute(
            sql: """
                UPDATE lyrics SET offsetMs = ?1 WHERE offsetMs <> ?1 AND EXISTS (
                    SELECT 1 FROM tracks t JOIN sync_song_keys k ON k.trackId = t.id
                    WHERE k.songKey = ?2 AND t.title = lyrics.trackTitle AND t.artist = lyrics.artist)
                """,
            arguments: [offsetMs, songKey]
        )
        return db.changesCount > 0
    }

    private static func tracksSignature(_ db: Database) throws -> String {
        let row = try Row.fetchOne(
            db,
            sql: "SELECT COUNT(*) AS n, COALESCE(MAX(id), 0) AS newest, COALESCE(SUM(id), 0) AS total, COALESCE(SUM(revision), 0) AS revisions FROM tracks"
        )
        let n: Int = row?["n"] ?? 0
        let newest: Int64 = row?["newest"] ?? 0
        let total: Int64 = row?["total"] ?? 0
        let revisions: Int64 = row?["revisions"] ?? 0
        return "\(n):\(newest):\(total):\(revisions)"
    }

    /// Re-resolves every synced playlist against the library as it now is, so an entry hidden for want of its file appears when the
    /// file does, and reapplies synced lyrics offsets to lyrics fetched since. Does nothing while the library is unchanged.
    static func resolveGhosts(_ db: Database) throws -> MaterializeOutcome {
        guard let caller = try caller(db) else { return MaterializeOutcome() }
        let signature = try tracksSignature(db)
        guard try SyncMeta.get(db, SyncMeta.tracksSignature) != signature else { return MaterializeOutcome() }
        var dirty = SyncDirty()
        dirty.playlists.formUnion(try SyncBase.ids(db, kind: SyncBase.playlist))
        dirty.playlists.formUnion(try String.fetchAll(db, sql: "SELECT syncId FROM playlists WHERE syncId IS NOT NULL"))
        dirty.scalars.formUnion(try SyncBase.ids(db, kind: SyncBase.scalar).filter { $0.hasPrefix(lyricsPrefix) })
        let outcome = try refresh(db, dirty: dirty, caller: caller)
        try SyncMeta.set(db, SyncMeta.tracksSignature, signature)
        return outcome
    }
}
