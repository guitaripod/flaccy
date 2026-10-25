import Foundation
import FlaccyCore
import GRDB

/// Listen keys computed once per distinct spelling: a history repeats the same
/// few thousand titles, artists and albums across a hundred thousand plays.
public struct ListenKeyMemo {

    private var titles: [String: String] = [:]
    private var artists: [String: String] = [:]
    private var albums: [String: String] = [:]

    public init() {}

    public mutating func keys(title: String, artist: String, album: String) -> (title: String, artist: String, album: String) {
        (
            Self.memoized(&titles, title, ListenHistory.titleKey),
            Self.memoized(&artists, artist, ListenHistory.artistKey),
            Self.memoized(&albums, album, ListenHistory.albumKey)
        )
    }

    private static func memoized(
        _ memo: inout [String: String], _ raw: String, _ key: (String) -> String
    ) -> String {
        if let found = memo[raw] { return found }
        let computed = key(raw)
        memo[raw] = computed
        return computed
    }
}

extension DatabaseManager {

    /// Scrobbles keyed per write transaction while filling, so a long history
    /// never holds the database for more than a few tens of milliseconds.
    static let listenKeyFillChunk = 5_000

    /// Fills the listen keys of the scrobbles stored before the key columns
    /// existed, a chunk per write, then builds the key indexes (after the
    /// fill, so they are not maintained row by row) and returns how many rows
    /// it filled. Rows still waiting have an empty title key and a title,
    /// found through the key index once it exists, so asking again costs one
    /// seek. Call it off the main actor: a first fill of a long history takes
    /// a second or so.
    @discardableResult
    public func fillListenKeys() throws -> Int {
        var memo = ListenKeyMemo()
        var filled = 0
        var afterID = Int64.min
        while true {
            let chunk = try dbQueue.write { db -> Int in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT id, trackTitle, artist, albumTitle FROM scrobbles
                        WHERE id > ? AND titleKey = '' AND trackTitle <> '' ORDER BY id LIMIT ?
                        """,
                    arguments: [afterID, Self.listenKeyFillChunk]
                )
                if let last = rows.last {
                    afterID = last["id"]
                }
                let update = try db.cachedStatement(
                    sql: "UPDATE scrobbles SET titleKey = ?, artistKey = ?, albumKey = ? WHERE id = ?"
                )
                for row in rows {
                    let id: Int64 = row["id"]
                    let keys = memo.keys(title: row["trackTitle"], artist: row["artist"], album: row["albumTitle"])
                    try update.execute(arguments: [keys.title, keys.artist, keys.album, id])
                }
                return rows.count
            }
            filled += chunk
            if chunk < Self.listenKeyFillChunk { break }
        }
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS scrobbles_on_listen_play ON scrobbles(titleKey, artistKey, timestamp);
                CREATE INDEX IF NOT EXISTS scrobbles_on_artistKey ON scrobbles(artistKey);
                """)
        }
        if filled > 0 {
            scrobbleRevisionCounter.bump()
        }
        return filled
    }

    /// The sync state stored for a Last.fm account, nil before its first sync.
    public func listenSyncState(account: String) throws -> ListenHistory.SyncState? {
        try dbQueue.read { db in
            guard let json = try String.fetchOne(
                db, sql: "SELECT state FROM listenSync WHERE account = ?", arguments: [account]
            ) else { return nil }
            return try JSONDecoder().decode(ListenHistory.SyncState.self, from: Data(json.utf8))
        }
    }

    public func saveListenSyncState(_ state: ListenHistory.SyncState) throws {
        let json = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO listenSync (account, state) VALUES (?, ?)",
                arguments: [state.account, json]
            )
        }
    }
}
