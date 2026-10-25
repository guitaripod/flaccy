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

    /// Fills the listen keys of every stored scrobble, through one cached
    /// `UPDATE` inside the migration's transaction.
    static func fillListenKeys(_ db: Database) throws {
        let rows = try Row.fetchAll(db, sql: "SELECT id, trackTitle, artist, albumTitle FROM scrobbles")
        let update = try db.cachedStatement(
            sql: "UPDATE scrobbles SET titleKey = ?, artistKey = ?, albumKey = ? WHERE id = ?"
        )
        var memo = ListenKeyMemo()
        for row in rows {
            let id: Int64 = row["id"]
            let title: String = row["trackTitle"]
            let artist: String = row["artist"]
            let album: String = row["albumTitle"]
            let keys = memo.keys(title: title, artist: artist, album: album)
            try update.execute(arguments: [keys.title, keys.artist, keys.album, id])
        }
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
