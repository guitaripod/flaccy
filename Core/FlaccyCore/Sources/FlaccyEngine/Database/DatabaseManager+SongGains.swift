import FlaccyCore
import Foundation
import GRDB

extension DatabaseManager {

    /// The person's own volume for a song, in tenths of a decibel: 0 when they
    /// never set one. Mirrors `Db::song_gain` in the Linux client.
    public func songGain(title: String, artist: String) throws -> Int {
        let key = try ServerSongIdentity.songKey(title: title, artist: artist)
        return try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT tenths FROM songGains WHERE songKey = ?", arguments: [key]) ?? 0
        }
    }

    /// Every song the person gave a volume of its own, by song key.
    public func songGains() throws -> [String: Int] {
        try dbQueue.read { db in
            var levels: [String: Int] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT songKey, tenths FROM songGains") {
                levels[row["songKey"]] = row["tenths"]
            }
            return levels
        }
    }

    /// Sets a song's own volume and queues it for Flaccy Server; 0 forgets it.
    /// Returns the level stored, kept inside what the controls offer. Mirrors
    /// `Db::set_song_gain` in the Linux client.
    @discardableResult
    public func setSongGain(title: String, artist: String, tenths: Int) throws -> Int {
        let level = SongGain.clamped(tenths)
        let key = try ServerSongIdentity.songKey(title: title, artist: artist)
        try dbQueue.write { db in
            guard try SongGainTable.write(db, songKey: key, tenths: level) else { return }
            try ServerSyncRecorder(db, gate: serverSyncGate)?.songGain(songKey: key, tenths: level)
        }
        return level
    }
}

/// The `songGains` table: one row per song with a volume of its own, keyed the way Flaccy Server keys it.
enum SongGainTable {

    /// Stores a level, forgetting it at 0. True when the stored level changed.
    static func write(_ db: Database, songKey: String, tenths: Int) throws -> Bool {
        if tenths == 0 {
            try db.execute(sql: "DELETE FROM songGains WHERE songKey = ?", arguments: [songKey])
        } else {
            try db.execute(
                sql: """
                    INSERT INTO songGains (songKey, tenths) VALUES (?1, ?2)
                    ON CONFLICT(songKey) DO UPDATE SET tenths = excluded.tenths WHERE tenths <> excluded.tenths
                    """,
                arguments: [songKey, tenths]
            )
        }
        return db.changesCount > 0
    }
}
