import Foundation
import GRDB

nonisolated struct TrackRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {

    static let databaseTableName = "tracks"

    var id: Int64?
    var fileURL: String
    var title: String
    var artist: String
    var albumTitle: String
    var trackNumber: Int
    var duration: Double
    var artworkData: Data?
    var lastFMArtworkURL: String?
    var musicBrainzID: String?
    var albumMusicBrainzID: String?
    var dateAdded: Date
    var lastPlayed: Date?
    var playCount: Int
    var aiAnalyzed: Bool
}

nonisolated struct ArtistRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {

    static let databaseTableName = "artists"

    var id: Int64?
    var name: String
    var bio: String?
    var imageURL: String?
    var musicBrainzID: String?
    var lastFetched: Date?
}

nonisolated struct AlbumInfoRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {

    static let databaseTableName = "albumInfo"

    var id: Int64?
    var title: String
    var artist: String
    var coverArtURL: String?
    var coverArtData: Data?
    var musicBrainzID: String?
    var year: String?
    var genre: String?
    var lastFetched: Date?
}

nonisolated struct ScrobbleRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {

    static let databaseTableName = "scrobbles"

    var id: Int64?
    var trackTitle: String
    var artist: String
    var albumTitle: String
    var timestamp: Date
    var duration: Int
    var submitted: Bool
}

nonisolated struct PlaylistRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {

    static let databaseTableName = "playlists"

    var id: Int64?
    var name: String
    var createdAt: Date
}

nonisolated struct PlaylistTrackRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {

    static let databaseTableName = "playlistTracks"

    var id: Int64?
    var playlistId: Int64
    var trackFileURL: String
    var position: Int
}

final class DatabaseManager {

    static let shared = DatabaseManager()

    private let dbQueue: DatabaseQueue

    init() {
        do {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let dbDirectory = appSupport.appendingPathComponent("flaccy", isDirectory: true)
            try FileManager.default.createDirectory(at: dbDirectory, withIntermediateDirectories: true)
            let dbPath = dbDirectory.appendingPathComponent("library.sqlite").path
            dbQueue = try DatabaseQueue(path: dbPath)
            try runMigrations()
            AppLogger.info("Database initialized at \(dbPath)", category: .database)
        } catch {
            fatalError("Failed to initialize database: \(error)")
        }
    }

    private func runMigrations() throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "tracks") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("fileURL", .text).notNull().unique()
                t.column("title", .text).notNull()
                t.column("artist", .text).notNull()
                t.column("albumTitle", .text).notNull()
                t.column("trackNumber", .integer).notNull()
                t.column("duration", .double).notNull()
                t.column("artworkData", .blob)
                t.column("lastFMArtworkURL", .text)
                t.column("musicBrainzID", .text)
                t.column("albumMusicBrainzID", .text)
                t.column("dateAdded", .datetime).notNull()
                t.column("lastPlayed", .datetime)
                t.column("playCount", .integer).notNull().defaults(to: 0)
            }
            try db.create(index: "tracks_on_artist", on: "tracks", columns: ["artist"])
            try db.create(index: "tracks_on_albumTitle_artist", on: "tracks", columns: ["albumTitle", "artist"])

            try db.create(table: "artists") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull().unique()
                t.column("bio", .text)
                t.column("imageURL", .text)
                t.column("musicBrainzID", .text)
                t.column("lastFetched", .datetime)
            }

            try db.create(table: "albumInfo") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("title", .text).notNull()
                t.column("artist", .text).notNull()
                t.column("coverArtURL", .text)
                t.column("coverArtData", .blob)
                t.column("musicBrainzID", .text)
                t.column("year", .text)
                t.column("genre", .text)
                t.column("lastFetched", .datetime)
                t.uniqueKey(["title", "artist"])
            }
            try db.create(index: "albumInfo_on_artist", on: "albumInfo", columns: ["artist"])

            try db.create(table: "scrobbles") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("trackTitle", .text).notNull()
                t.column("artist", .text).notNull()
                t.column("albumTitle", .text).notNull()
                t.column("timestamp", .datetime).notNull()
                t.column("duration", .integer).notNull()
                t.column("submitted", .boolean).notNull().defaults(to: false)
            }
            try db.create(index: "scrobbles_on_submitted", on: "scrobbles", columns: ["submitted"])
        }

        migrator.registerMigration("v2") { db in
            try db.alter(table: "tracks") { t in
                t.add(column: "aiAnalyzed", .boolean).notNull().defaults(to: false)
            }
        }

        migrator.registerMigration("v3") { db in
            try db.create(table: "playlists") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }

            try db.create(table: "playlistTracks") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("playlistId", .integer).notNull().references("playlists", onDelete: .cascade)
                t.column("trackFileURL", .text).notNull()
                t.column("position", .integer).notNull()
            }
            try db.create(index: "playlistTracks_on_playlistId", on: "playlistTracks", columns: ["playlistId"])
        }

        try migrator.migrate(dbQueue)
    }

    @discardableResult
    func insertTrack(_ track: TrackRecord) throws -> TrackRecord {
        try dbQueue.write { db in
            try track.insertAndFetch(db, as: TrackRecord.self)
        }
    }

    func updateTrack(_ track: TrackRecord) throws {
        try dbQueue.write { db in
            try track.update(db)
        }
    }

    func fetchAllTracks() throws -> [TrackRecord] {
        try dbQueue.read { db in
            try TrackRecord.fetchAll(db)
        }
    }

    func fetchTrack(byRelativePath path: String) throws -> TrackRecord? {
        try dbQueue.read { db in
            try TrackRecord.filter(Column("fileURL") == path).fetchOne(db)
        }
    }

    func deleteTrack(id: Int64) throws {
        try dbQueue.write { db in
            _ = try TrackRecord.deleteOne(db, id: id)
        }
    }

    func deleteTracksNotIn(relativePaths: Set<String>) throws {
        try dbQueue.write { db in
            if relativePaths.isEmpty {
                _ = try TrackRecord.deleteAll(db)
            } else {
                _ = try TrackRecord.filter(!relativePaths.contains(Column("fileURL"))).deleteAll(db)
            }
        }
    }

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

    func fetchArtist(name: String) throws -> ArtistRecord? {
        try dbQueue.read { db in
            try ArtistRecord.filter(Column("name") == name).fetchOne(db)
        }
    }

    func fetchOrCreateAlbumInfo(title: String, artist: String) throws -> AlbumInfoRecord {
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

    func updateAlbumInfo(_ album: AlbumInfoRecord) throws {
        try dbQueue.write { db in
            try album.update(db)
        }
    }

    func fetchAlbumInfo(title: String, artist: String) throws -> AlbumInfoRecord? {
        try dbQueue.read { db in
            try AlbumInfoRecord
                .filter(Column("title") == title && Column("artist") == artist)
                .fetchOne(db)
        }
    }

    func insertScrobble(_ scrobble: ScrobbleRecord) throws {
        try dbQueue.write { db in
            try scrobble.insert(db)
        }
    }

    func fetchPendingScrobbles() throws -> [ScrobbleRecord] {
        try dbQueue.read { db in
            try ScrobbleRecord
                .filter(Column("submitted") == false)
                .order(Column("timestamp").asc)
                .fetchAll(db)
        }
    }

    func markScrobblesSubmitted(ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        _ = try dbQueue.write { db in
            try ScrobbleRecord
                .filter(ids.contains(Column("id")))
                .updateAll(db, Column("submitted").set(to: true))
        }
    }

    func resetAllAIAnalyzed() throws {
        try dbQueue.write { db in
            try TrackRecord
                .updateAll(db, Column("aiAnalyzed").set(to: false))
        }
    }

    func incrementPlayCount(trackId: Int64) throws {
        try dbQueue.write { db in
            if var track = try TrackRecord.fetchOne(db, id: trackId) {
                track.playCount += 1
                track.lastPlayed = Date()
                try track.update(db)
            }
        }
    }

    func fetchAlbumsWithTracks() throws -> [(album: AlbumInfoRecord?, tracks: [TrackRecord])] {
        try dbQueue.read { db in
            let allTracks = try TrackRecord
                .order(Column("albumTitle").collating(.localizedCaseInsensitiveCompare).asc,
                       Column("artist").collating(.localizedCaseInsensitiveCompare).asc,
                       Column("trackNumber").asc,
                       Column("title").collating(.localizedCaseInsensitiveCompare).asc)
                .fetchAll(db)

            let grouped: [(key: String, tracks: [TrackRecord])] = {
                var order: [String] = []
                var map: [String: [TrackRecord]] = [:]
                for track in allTracks {
                    let key = "\(track.albumTitle)\0\(track.artist)"
                    if map[key] == nil {
                        order.append(key)
                    }
                    map[key, default: []].append(track)
                }
                return order.map { (key: $0, tracks: map[$0]!) }
            }()

            var results: [(album: AlbumInfoRecord?, tracks: [TrackRecord])] = []
            for group in grouped {
                guard let first = group.tracks.first else { continue }
                let albumInfo = try AlbumInfoRecord
                    .filter(Column("title") == first.albumTitle && Column("artist") == first.artist)
                    .fetchOne(db)
                results.append((album: albumInfo, tracks: group.tracks))
            }
            return results
        }
    }

    @discardableResult
    func createPlaylist(name: String) throws -> PlaylistRecord {
        try dbQueue.write { db in
            try PlaylistRecord(name: name, createdAt: Date())
                .insertAndFetch(db, as: PlaylistRecord.self)
        }
    }

    func deletePlaylist(id: Int64) throws {
        try dbQueue.write { db in
            _ = try PlaylistRecord.deleteOne(db, id: id)
        }
    }

    func fetchAllPlaylists() throws -> [PlaylistRecord] {
        try dbQueue.read { db in
            try PlaylistRecord.order(Column("createdAt").desc).fetchAll(db)
        }
    }

    func addTrackToPlaylist(playlistId: Int64, trackFileURL: String) throws {
        try dbQueue.write { db in
            let maxPosition = try Int.fetchOne(
                db,
                sql: "SELECT COALESCE(MAX(position), -1) FROM playlistTracks WHERE playlistId = ?",
                arguments: [playlistId]
            ) ?? -1

            try PlaylistTrackRecord(
                playlistId: playlistId,
                trackFileURL: trackFileURL,
                position: maxPosition + 1
            ).insert(db)
        }
    }

    func removeTrackFromPlaylist(id: Int64) throws {
        try dbQueue.write { db in
            _ = try PlaylistTrackRecord.deleteOne(db, id: id)
        }
    }

    func fetchPlaylistTracks(playlistId: Int64) throws -> [PlaylistTrackRecord] {
        try dbQueue.read { db in
            try PlaylistTrackRecord
                .filter(Column("playlistId") == playlistId)
                .order(Column("position").asc)
                .fetchAll(db)
        }
    }

    func fetchPlaylistTrackCount(playlistId: Int64) throws -> Int {
        try dbQueue.read { db in
            try PlaylistTrackRecord
                .filter(Column("playlistId") == playlistId)
                .fetchCount(db)
        }
    }

    func reorderPlaylistTrack(id: Int64, newPosition: Int) throws {
        try dbQueue.write { db in
            if var record = try PlaylistTrackRecord.fetchOne(db, id: id) {
                record.position = newPosition
                try record.update(db)
            }
        }
    }

    func fetchRecentlyPlayedAlbums(limit: Int) throws -> [(albumTitle: String, artist: String)] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT DISTINCT albumTitle, artist FROM tracks
                WHERE lastPlayed IS NOT NULL
                ORDER BY lastPlayed DESC
                LIMIT ?
            """, arguments: [limit])
            return rows.map { (albumTitle: $0["albumTitle"], artist: $0["artist"]) }
        }
    }
}
