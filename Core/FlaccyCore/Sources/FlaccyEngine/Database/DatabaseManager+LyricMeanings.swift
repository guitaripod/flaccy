import Foundation
import GRDB

extension DatabaseManager {

    /// A stored reading of a song's meaning (`MeaningCache` names the scopes)
    /// with how many days old it is. Mirrors `Db::fetch_lyric_meaning` in the
    /// Linux client.
    public func lyricMeaning(
        trackTitle: String, artist: String, scope: String, language: String
    ) throws -> (body: String, ageDays: Double)? {
        try dbQueue.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT body, julianday('now') - julianday(fetchedAt) AS age FROM lyricMeanings
                WHERE trackTitle = ? AND artist = ? AND scope = ? AND language = ?
                """, arguments: [trackTitle, artist, scope, language])
            guard let row else { return nil }
            let age: Double? = row["age"]
            return (row["body"], age ?? .greatestFiniteMagnitude)
        }
    }

    /// Remembers a reading, replacing an older one for the same question.
    public func saveLyricMeaning(
        trackTitle: String, artist: String, scope: String, language: String, body: String, at date: Date = Date()
    ) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO lyricMeanings (trackTitle, artist, scope, language, body, fetchedAt)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(trackTitle, artist, scope, language) DO UPDATE SET
                    body = excluded.body,
                    fetchedAt = excluded.fetchedAt
                """, arguments: [trackTitle, artist, scope, language, body, date])
        }
    }
}
