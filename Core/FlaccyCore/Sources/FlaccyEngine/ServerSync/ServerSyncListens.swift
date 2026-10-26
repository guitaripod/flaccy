import FlaccyCore
import Foundation
import GRDB

/// The next `GET /listens` the engine wants: exactly one of `before` and `after` is set.
struct ListensRequest: Sendable, Equatable {
    var before: Int64?
    var after: Int64?
    var limit: Int
}

/// One stored play, as a `listen.record` carries it.
struct StoredPlay: Sendable {
    var eventId: String
    var ts: Int64
    var title: String
    var artist: String
    var album: String
    var duration: Int
    var titleKey: String
    var artistKey: String
    var albumKey: String
}

/// Reading the play history back from the server, and queueing the local one for it.
enum SyncListens {

    static let pageLimit = 5_000
    static let batchSize = 500
    static let farFuture: Int64 = 4_102_444_800
    static let tail = "tail"

    static func nextRequest(_ db: Database) throws -> ListensRequest {
        if try SyncMeta.get(db, SyncMeta.listensPhase) == tail {
            return ListensRequest(before: nil, after: try SyncMeta.int(db, SyncMeta.listensAfter) ?? 0, limit: pageLimit)
        }
        return ListensRequest(before: try SyncMeta.int(db, SyncMeta.listensBefore) ?? farFuture, after: nil, limit: pageLimit)
    }

    static func backfillDone(_ db: Database) throws -> Bool {
        try SyncMeta.get(db, SyncMeta.listensPhase) == tail
    }

    /// Stores a page and moves the paging state, in the caller's transaction. Answers how many rows were written.
    static func apply(_ db: Database, page: ServerListensPage, memo: inout ListenKeyMemo) throws -> Int {
        let written = try upsert(db, page.listens, memo: &memo)
        if try SyncMeta.get(db, SyncMeta.listensPhase) == tail {
            if let last = page.listens.last {
                try SyncMeta.setInt(db, SyncMeta.listensAfter, last.seq)
            }
            return written
        }
        if try SyncMeta.get(db, SyncMeta.listensTailFrom) == nil {
            try SyncMeta.setInt(db, SyncMeta.listensTailFrom, page.head)
        }
        let requested = try SyncMeta.int(db, SyncMeta.listensBefore) ?? farFuture
        if page.more, let oldest = page.listens.map(\.ts).min() {
            let candidate = oldest + 1
            try SyncMeta.setInt(db, SyncMeta.listensBefore, candidate >= requested ? oldest : candidate)
        } else {
            try SyncMeta.setInt(db, SyncMeta.listensAfter, try SyncMeta.int(db, SyncMeta.listensTailFrom) ?? 0)
            try SyncMeta.set(db, SyncMeta.listensPhase, tail)
        }
        return written
    }

    /// Forgets the paging position after a server restore, so plays are read again and applied idempotently.
    static func rewind(_ db: Database) throws {
        if try SyncMeta.get(db, SyncMeta.listensPhase) == tail {
            try SyncMeta.setInt(db, SyncMeta.listensAfter, 0)
            return
        }
        try SyncMeta.remove(db, SyncMeta.listensBefore)
        try SyncMeta.remove(db, SyncMeta.listensTailFrom)
    }

    private static func upsert(_ db: Database, _ listens: [ServerListenItem], memo: inout ListenKeyMemo) throws -> Int {
        let adopt = try db.cachedStatement(sql: """
            UPDATE scrobbles SET eventId = ?1, suppressed = ?2
            WHERE eventId IS NULL AND titleKey = ?3 AND CAST(strftime('%s', timestamp) AS INTEGER) = ?4
              AND NOT EXISTS (SELECT 1 FROM scrobbles WHERE eventId = ?1)
            """)
        let upsert = try db.cachedStatement(sql: """
            INSERT INTO scrobbles
                (trackTitle, artist, albumTitle, timestamp, duration, submitted, titleKey, artistKey, albumKey, eventId, suppressed)
            VALUES (?1, ?2, ?3, ?4, ?5, 1, ?6, ?7, ?8, ?9, ?10)
            ON CONFLICT(eventId) WHERE eventId IS NOT NULL DO UPDATE SET suppressed = excluded.suppressed
            WHERE scrobbles.suppressed <> excluded.suppressed
            """)
        var written = 0
        for item in listens {
            let song = item.ref
            let keys = memo.keys(title: song.title, artist: song.artist, album: song.album)
            try adopt.execute(arguments: [item.eventId, item.suppressed, keys.title, item.ts])
            written += db.changesCount
            try upsert.execute(arguments: [
                song.title, song.artist, song.album, Date(timeIntervalSince1970: TimeInterval(item.ts)), item.playedS,
                keys.title, keys.artist, keys.album, item.eventId, item.suppressed,
            ])
            written += db.changesCount
        }
        return written
    }

    /// The `listen` documents of stored plays, with song keys computed in one call.
    static func listenDocuments(_ plays: [StoredPlay]) throws -> [ServerJSON] {
        var pairs: [String: Int] = [:]
        var ordered: [(artistKey: String, titleKey: String)] = []
        for play in plays {
            let identity = play.artistKey + "\u{0}" + play.titleKey
            if pairs[identity] == nil {
                pairs[identity] = ordered.count
                ordered.append((play.artistKey, play.titleKey))
            }
        }
        let songKeys = try ServerCoreBridge.songKeys(ordered)
        return try plays.map { play in
            let index = pairs[play.artistKey + "\u{0}" + play.titleKey] ?? 0
            let ref = ServerSongRef(
                songKey: songKeys[index], title: play.title, artist: play.artist, album: play.album,
                albumKey: play.albumKey.isEmpty ? nil : play.albumKey
            )
            return try ServerCoreBridge.json(ServerListenInput(
                eventId: play.eventId, ts: play.ts, ref: ref, playedS: Int64(play.duration), recorded: play.duration > 0
            ))
        }
    }

    static func recordMutation(_ listens: [ServerJSON]) -> NewMutation {
        NewMutation(SyncPending.listenRecord, ["listens": .array(listens)])
    }

    /// Reads stored plays that have an event id, `limit` at a time after `afterRow`, with their keys filled in.
    static func storedPlays(_ db: Database, afterRow: Int64, limit: Int, memo: inout ListenKeyMemo) throws -> (plays: [StoredPlay], lastRow: Int64) {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, eventId, CAST(strftime('%s', timestamp) AS INTEGER) AS ts, trackTitle, artist, albumTitle,
                       duration, titleKey, artistKey, albumKey
                FROM scrobbles WHERE id > ? AND eventId IS NOT NULL ORDER BY id LIMIT ?
                """,
            arguments: [afterRow, limit]
        )
        let plays = rows.map { row -> StoredPlay in
            let title: String = row["trackTitle"]
            let artist: String = row["artist"]
            let album: String = row["albumTitle"]
            let titleKey: String = row["titleKey"]
            let keys = titleKey.isEmpty ? memo.keys(title: title, artist: artist, album: album) : nil
            return StoredPlay(
                eventId: row["eventId"], ts: row["ts"], title: title, artist: artist, album: album,
                duration: row["duration"],
                titleKey: keys?.title ?? titleKey, artistKey: keys?.artist ?? row["artistKey"],
                albumKey: keys?.album ?? row["albumKey"]
            )
        }
        return (plays, rows.last.map { $0["id"] as Int64 } ?? afterRow)
    }

    /// Every stored play with an event id as `listen.record` mutations, for a server that lost them.
    static func requeueAll(_ db: Database) throws -> [NewMutation] {
        var memo = ListenKeyMemo()
        var mutations: [NewMutation] = []
        var cursor: Int64 = 0
        while true {
            let (plays, last) = try storedPlays(db, afterRow: cursor, limit: pageLimit, memo: &memo)
            if plays.isEmpty { break }
            cursor = last
            for batch in try listenDocuments(plays).chunked(into: batchSize) {
                mutations.append(recordMutation(batch))
            }
        }
        return mutations
    }
}
