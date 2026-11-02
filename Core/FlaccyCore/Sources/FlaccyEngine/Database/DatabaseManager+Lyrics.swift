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
            try ServerSyncRecorder(db, gate: serverSyncGate)?.lyricsOffset(title: trackTitle, artist: artist, offsetMs: offsetMs)
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

    /// The songs whose lyrics a background pass still has to ask about: none
    /// stored yet, a miss old enough to ask again about, or content from
    /// before `revision`. The same rule as `LyricsResolution.isCurrent`, so a
    /// song this returns is a song `LyricsService.fetchLyrics` would look up.
    /// A title and artist that several files share is listed once.
    public func songsWantingLyrics(revision: Int, missesFetchedBefore cutoff: Date) throws -> [LyricsWant] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT t.title, t.artist, t.albumTitle, t.albumArtist, t.fileURL, t.duration, t.dateAdded, t.lastPlayed
                FROM tracks t
                LEFT JOIN lyrics l ON l.trackTitle = t.title AND l.artist = t.artist
                WHERE t.title <> '' AND t.artist <> '' AND (
                    l.id IS NULL
                    OR ((\(Self.lyricsHaveContent)) AND l.revision < ?)
                    OR (NOT (\(Self.lyricsHaveContent)) AND (l.fetchedAt IS NULL OR l.fetchedAt < ?))
                )
                """, arguments: [revision, cutoff])
            var seen = Set<String>()
            return rows.compactMap { row -> LyricsWant? in
                let title: String = row["title"]
                let artist: String = row["artist"]
                guard seen.insert(title + "\u{0}" + artist).inserted else { return nil }
                return LyricsWant(
                    title: title, artist: artist, albumTitle: row["albumTitle"], albumArtist: row["albumArtist"],
                    storedPath: row["fileURL"], duration: row["duration"],
                    dateAdded: row["dateAdded"], lastPlayed: row["lastPlayed"]
                )
            }
        }
    }

    /// The SQL for "this lyrics row holds something to show", mirroring
    /// `LyricsResolution.hasContent`.
    private static let lyricsHaveContent = """
        l.instrumental = 1
        OR TRIM(COALESCE(l.syncedLyrics, ''), ' ' || char(9, 10, 13)) <> ''
        OR TRIM(COALESCE(l.plainLyrics, ''), ' ' || char(9, 10, 13)) <> ''
        OR TRIM(COALESCE(l.lyricsfile, ''), ' ' || char(9, 10, 13)) <> ''
        """
}

/// A song a background pass may still need lyrics for, with what ranks it.
public struct LyricsWant: Sendable, Equatable {
    public let title: String
    public let artist: String
    public let albumTitle: String
    public let albumArtist: String?
    public let storedPath: String
    public let duration: Double
    public let dateAdded: Date
    public let lastPlayed: Date?
}
