import Foundation
import MidgarCore
import FlaccyCore
import GRDB

extension DatabaseManager {

    public func fetchLyrics(trackTitle: String, artist: String) throws -> LyricsRecord? {
        try dbQueue.read { db in
            try LyricsRecord
                .filter(Column("trackTitle") == trackTitle && Column("artist") == artist)
                .fetchOne(db)
        }
    }

    public func saveLyrics(_ record: LyricsRecord) throws {
        try dbQueue.write { db in
            try record.save(db)
        }
    }

    /// Remembers the listener's timing correction for one track's lyrics.
    /// Mirrors `Db::save_lyrics_offset` in the Linux client.
    public func saveLyricsOffset(trackTitle: String, artist: String, offsetMs: Int) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE lyrics SET offsetMs = ? WHERE trackTitle = ? AND artist = ?",
                arguments: [offsetMs, trackTitle, artist]
            )
        }
    }

    /// Marks a row as current without changing what it holds, for when the
    /// source was asked again and had nothing better. Mirrors
    /// `Db::set_lyrics_revision` in the Linux client.
    public func setLyricsRevision(trackTitle: String, artist: String, revision: Int) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE lyrics SET revision = ? WHERE trackTitle = ? AND artist = ?",
                arguments: [revision, trackTitle, artist]
            )
        }
    }
}
