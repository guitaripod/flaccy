import Foundation
import MidgarCore
import FlaccyCore
import GRDB

extension DatabaseManager {

    func fetchOrCreateArtist(name: String) throws -> ArtistRecord {
        try dbQueue.write { db in
            if let existing = try ArtistRecord.filter(Column("name") == name).fetchOne(db) {
                return existing
            }
            return try ArtistRecord(name: name).insertAndFetch(db, as: ArtistRecord.self)
        }
    }

    func updateArtist(_ artist: ArtistRecord) throws {
        try dbQueue.write { db in
            try artist.update(db)
        }
    }

    public func fetchArtist(name: String) throws -> ArtistRecord? {
        try dbQueue.read { db in
            try ArtistRecord.filter(Column("name") == name).fetchOne(db)
        }
    }

    public func fetchOrCreateAlbumInfo(title: String, artist: String) throws -> AlbumInfoRecord {
        try dbQueue.write { db in
            if let existing = try AlbumInfoRecord
                .filter(Column("title") == title && Column("artist") == artist)
                .fetchOne(db) {
                return existing
            }
            return try AlbumInfoRecord(title: title, artist: artist)
                .insertAndFetch(db, as: AlbumInfoRecord.self)
        }
    }

    /// Stores album artwork once per album (first-writer-wins) instead of
    /// duplicating the BLOB on every track row.
    public func saveAlbumCoverArtIfMissing(title: String, artist: String, data: Data) throws {
        try dbQueue.write { db in
            try Self.saveAlbumCoverArtIfMissing(title: title, artist: artist, data: data, in: db)
        }
    }

    static func saveAlbumCoverArtIfMissing(title: String, artist: String, data: Data, in db: Database) throws {
        try db.execute(sql: """
            INSERT INTO albumInfo (title, artist, coverArtData) VALUES (?, ?, ?)
            ON CONFLICT(title, artist) DO UPDATE SET coverArtData = excluded.coverArtData
            WHERE albumInfo.coverArtData IS NULL
        """, arguments: [title, artist, data])
    }

    public func updateAlbumInfo(_ album: AlbumInfoRecord) throws {
        try dbQueue.write { db in
            try album.update(db)
        }
    }

    public func fetchAlbumInfo(title: String, artist: String) throws -> AlbumInfoRecord? {
        try dbQueue.read { db in
            try AlbumInfoRecord
                .filter(Column("title") == title && Column("artist") == artist)
                .fetchOne(db)
        }
    }

    /// Reports what an album is still missing without touching `coverArtData`,
    /// so deciding whether to enrich a thousand albums never pulls a thousand
    /// JPEGs through SQLite.
    public func fetchAlbumInfoStatus(title: String, artist: String) throws -> (hasCover: Bool, year: String?, genre: String?, mbid: String?) {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT CASE WHEN coverArtData IS NOT NULL THEN 1 ELSE 0 END AS hasCover,
                       year, genre, musicBrainzID
                FROM albumInfo WHERE title = ? AND artist = ?
                """, arguments: [title, artist]) else {
                return (hasCover: false, year: nil, genre: nil, mbid: nil)
            }
            let hasCover: Int = row["hasCover"]
            return (hasCover: hasCover != 0, year: row["year"], genre: row["genre"], mbid: row["musicBrainzID"])
        }
    }
}
