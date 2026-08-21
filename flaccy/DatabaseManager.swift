import Foundation
import FlaccyCore
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
    var analysisAttemptedAt: Date?
    var codec: String?
    var bitDepth: Int?
    var sampleRate: Int?
    var channels: Int?
    var loved: Bool = false
    var lovedPendingOp: String?
}

nonisolated struct LightTrackRecord: Codable, FetchableRecord, Identifiable, Sendable {

    var id: Int64?
    var fileURL: String
    var title: String
    var artist: String
    var albumTitle: String
    var trackNumber: Int
    var duration: Double
    var dateAdded: Date
    var lastPlayed: Date?
    var playCount: Int
    var loved: Bool = false
    var codec: String?
    var bitDepth: Int?
    var sampleRate: Int?
    var channels: Int?
}

nonisolated struct WeeklyChartCacheRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {

    static let databaseTableName = "weeklyChartCache"

    var id: Int64?
    var chartType: String
    var fromUts: Int
    var toUts: Int
    var name: String
    var artist: String?
    var playCount: Int
    var rank: Int
}

nonisolated struct SimilarArtistCacheRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {

    static let databaseTableName = "similarArtistCache"

    var id: Int64?
    var artist: String
    var similarName: String
    var match: Double
    var fetchedAt: Date
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

nonisolated struct LyricsRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {

    static let databaseTableName = "lyrics"

    var id: Int64?
    var trackTitle: String
    var artist: String
    var syncedLyrics: String?
    var plainLyrics: String?
    var instrumental: Bool
    var fetchedAt: Date?
}

nonisolated struct WantlistRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {

    static let databaseTableName = "wantlist"

    var id: Int64?
    var normKey: String
    var kind: String
    var title: String
    var artist: String
    var imageURL: String?
    var state: String
    var source: String
    var score: Double
    var reason: String
    var playCount: Int
    var addedAt: Date
    var resolvedAt: Date?
    var acknowledged: Bool
}

nonisolated struct NewReleaseRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {

    static let databaseTableName = "newReleaseCache"

    var id: Int64?
    var artist: String
    var albumTitle: String
    var releaseDate: Date
    var imageURL: String?
    var storeURL: String?
    var fetchedAt: Date
}

nonisolated final class DatabaseManager: Sendable {

    static let shared = DatabaseManager()

    private let dbQueue: DatabaseQueue

    private init() {
        do {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let dbDirectory = appSupport.appendingPathComponent("flaccy", isDirectory: true)
            try FileManager.default.createDirectory(at: dbDirectory, withIntermediateDirectories: true)
            let dbPath = dbDirectory.appendingPathComponent("library.sqlite").path
            do {
                dbQueue = try Self.openDatabase(at: dbPath)
            } catch {
                AppLogger.error("Database open/migrate failed, recreating: \(error.localizedDescription)", category: .database)
                Self.moveCorruptDatabaseAside(at: dbPath)
                dbQueue = try Self.openDatabase(at: dbPath)
            }
            AppLogger.info("Database initialized at \(dbPath)", category: .database)
        } catch {
            fatalError("Failed to initialize database after recovery attempt: \(error)")
        }
    }

    /// Opens a database at an arbitrary path, for tests that need to watch the
    /// real migrator run against a fixture instead of the app's own library.
    /// Nothing in the app uses it: the app has exactly one database, `shared`.
    init(path: String) throws {
        dbQueue = try Self.openDatabase(at: path)
    }

    /// Opens the SQLite database and runs all migrations, throwing instead of crashing
    /// so a corrupt file can be moved aside and the library rebuilt from Documents.
    static func openDatabase(at path: String) throws -> DatabaseQueue {
        var configuration = Configuration()
        configuration.prepareDatabase { db in db.add(function: enrichmentKeyNormalizer) }
        let queue = try DatabaseQueue(path: path, configuration: configuration)
        try migrator().migrate(queue)
        return queue
    }

    /// The key normalizer every enrichment statement calls, installed on each
    /// connection before the migrator runs so the v10 seeds get it too.
    ///
    /// SQLite's own `lower()` folds ASCII only and its `trim()` strips spaces
    /// only, so an album titled "Ágætis byrjun" would be keyed one way by the
    /// queue and another by `EnrichmentKey`, which reads and writes the row —
    /// and the orphan sweep would delete the state on every sync that removes a
    /// file. `pure` maps to SQLITE_DETERMINISTIC, so the index seek on
    /// `enrichmentState(scope, key)` survives.
    private static let enrichmentKeyNormalizer = DatabaseFunction(
        EnrichmentKey.sqlFunctionName, argumentCount: 1, pure: true
    ) { arguments in
        guard let value = String.fromDatabaseValue(arguments[0]) else { return nil }
        return EnrichmentKey.normalize(value)
    }

    private static func moveCorruptDatabaseAside(at path: String) {
        let fm = FileManager.default
        let timestamp = Int(Date().timeIntervalSince1970)
        for suffix in ["", "-wal", "-shm"] {
            let source = path + suffix
            guard fm.fileExists(atPath: source) else { continue }
            let destination = path + ".corrupt-\(timestamp)" + suffix
            do {
                try fm.moveItem(atPath: source, toPath: destination)
            } catch {
                try? fm.removeItem(atPath: source)
            }
        }
    }

    static func migrator() -> DatabaseMigrator {
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

        migrator.registerMigration("v4") { db in
            try db.create(table: "lyrics") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("trackTitle", .text).notNull()
                t.column("artist", .text).notNull()
                t.column("syncedLyrics", .text)
                t.column("plainLyrics", .text)
                t.column("instrumental", .boolean).notNull().defaults(to: false)
                t.uniqueKey(["trackTitle", "artist"])
            }
        }

        migrator.registerMigration("v5") { db in
            try db.alter(table: "tracks") { t in
                t.add(column: "analysisAttemptedAt", .datetime)
            }

            try db.execute(sql: """
                INSERT INTO albumInfo (title, artist, coverArtData)
                SELECT albumTitle, artist, artworkData FROM tracks
                WHERE artworkData IS NOT NULL AND albumTitle <> ''
                GROUP BY albumTitle, artist
                ON CONFLICT(title, artist) DO UPDATE SET coverArtData = excluded.coverArtData
                WHERE albumInfo.coverArtData IS NULL
            """)
            try db.execute(sql: "UPDATE tracks SET artworkData = NULL WHERE artworkData IS NOT NULL AND albumTitle <> ''")

            try db.execute(sql: "DELETE FROM playlistTracks WHERE trackFileURL NOT IN (SELECT fileURL FROM tracks)")
        }

        migrator.registerMigration("v6") { db in
            try db.alter(table: "tracks") { t in
                t.add(column: "codec", .text)
                t.add(column: "bitDepth", .integer)
                t.add(column: "sampleRate", .integer)
                t.add(column: "channels", .integer)
                t.add(column: "loved", .boolean).notNull().defaults(to: false)
                t.add(column: "lovedPendingOp", .text)
            }
            try db.create(index: "tracks_on_loved", on: "tracks", columns: ["loved"])

            try db.create(table: "weeklyChartCache") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("chartType", .text).notNull()
                t.column("fromUts", .integer).notNull()
                t.column("toUts", .integer).notNull()
                t.column("name", .text).notNull()
                t.column("artist", .text)
                t.column("playCount", .integer).notNull().defaults(to: 0)
                t.column("rank", .integer).notNull().defaults(to: 0)
            }
            try db.create(index: "weeklyChartCache_on_type_range", on: "weeklyChartCache", columns: ["chartType", "fromUts", "toUts"])

            try db.create(table: "similarArtistCache") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("artist", .text).notNull()
                t.column("similarName", .text).notNull()
                t.column("match", .double).notNull().defaults(to: 0)
                t.column("fetchedAt", .datetime).notNull()
                t.uniqueKey(["artist", "similarName"])
            }
        }

        migrator.registerMigration("v7") { db in
            try db.create(table: "wantlist") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("normKey", .text).notNull().unique()
                t.column("kind", .text).notNull()
                t.column("title", .text).notNull()
                t.column("artist", .text).notNull()
                t.column("imageURL", .text)
                t.column("state", .text).notNull()
                t.column("source", .text).notNull()
                t.column("score", .double).notNull().defaults(to: 0)
                t.column("reason", .text).notNull().defaults(to: "")
                t.column("playCount", .integer).notNull().defaults(to: 0)
                t.column("addedAt", .datetime).notNull()
                t.column("resolvedAt", .datetime)
                t.column("acknowledged", .boolean).notNull().defaults(to: false)
            }
            try db.create(index: "wantlist_on_state", on: "wantlist", columns: ["state"])

            try db.create(table: "newReleaseCache") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("artist", .text).notNull()
                t.column("albumTitle", .text).notNull()
                t.column("releaseDate", .datetime).notNull()
                t.column("imageURL", .text)
                t.column("storeURL", .text)
                t.column("fetchedAt", .datetime).notNull()
                t.uniqueKey(["artist", "albumTitle"])
            }
        }

        migrator.registerMigration("v8") { db in
            try db.drop(index: "scrobbles_on_submitted")
            try db.create(index: "scrobbles_on_submitted_timestamp", on: "scrobbles", columns: ["submitted", "timestamp"])
            try db.create(index: "scrobbles_on_timestamp", on: "scrobbles", columns: ["timestamp"])
        }

        migrator.registerMigration("v9") { db in
            try db.alter(table: "lyrics") { t in
                t.add(column: "fetchedAt", .datetime)
            }
        }

        migrator.registerMigration("v10") { db in
            try db.create(table: "enrichmentState", options: [.withoutRowID]) { t in
                t.column("scope", .text).notNull()
                t.column("key", .text).notNull()
                t.column("version", .integer).notNull().defaults(to: 0)
                t.column("status", .integer).notNull().defaults(to: 0)
                t.column("fields", .integer).notNull().defaults(to: 0)
                t.column("attempts", .integer).notNull().defaults(to: 0)
                t.column("lastAttemptAt", .datetime)
                t.column("nextEligibleAt", .datetime)
                t.column("lastFailure", .text)
                t.primaryKey(["scope", "key"])
            }
            try db.create(
                index: "enrichmentState_on_due", on: "enrichmentState",
                columns: ["scope", "status", "nextEligibleAt"]
            )

            try db.create(table: "libraryDebut") { t in
                t.column("id", .integer).primaryKey().check { $0 == 1 }
                t.column("completedAt", .datetime).notNull()
                t.column("summaryJSON", .text).notNull()
            }

            try db.execute(sql: """
                INSERT INTO albumInfo (title, artist, coverArtData)
                SELECT albumTitle, artist, artworkData FROM tracks
                WHERE artworkData IS NOT NULL AND albumTitle <> ''
                GROUP BY albumTitle, artist
                ON CONFLICT(title, artist) DO UPDATE SET coverArtData = excluded.coverArtData
                WHERE albumInfo.coverArtData IS NULL
                """)
            try db.execute(sql: """
                UPDATE tracks SET artworkData = NULL
                WHERE artworkData IS NOT NULL AND albumTitle <> ''
                """)

            try db.execute(sql: """
                INSERT OR IGNORE INTO enrichmentState
                    (scope, key, version, status, fields, attempts, lastAttemptAt, nextEligibleAt, lastFailure)
                SELECT 'album',
                       flaccy_norm(title) || char(31) || flaccy_norm(artist),
                       0,
                       CASE WHEN coverArtData IS NOT NULL AND year IS NOT NULL THEN 1 ELSE 0 END,
                         (CASE WHEN coverArtData  IS NOT NULL THEN 1  ELSE 0 END)
                       + (CASE WHEN year          IS NOT NULL THEN 2  ELSE 0 END)
                       + (CASE WHEN genre         IS NOT NULL THEN 4  ELSE 0 END)
                       + (CASE WHEN musicBrainzID IS NOT NULL THEN 8  ELSE 0 END),
                       0, lastFetched, NULL, NULL
                FROM albumInfo
                """)

            try db.execute(sql: """
                INSERT OR IGNORE INTO enrichmentState
                    (scope, key, version, status, fields, attempts)
                SELECT 'artist',
                       flaccy_norm(name),
                       0,
                       CASE WHEN imageURL IS NOT NULL THEN 1 ELSE 0 END,
                         (CASE WHEN bio      IS NOT NULL THEN 16 ELSE 0 END)
                       + (CASE WHEN imageURL IS NOT NULL THEN 32 ELSE 0 END),
                       0
                FROM artists
                """)

            try db.execute(sql: """
                INSERT OR IGNORE INTO enrichmentState
                    (scope, key, version, status, fields, attempts)
                SELECT 'aiBatch',
                       flaccy_norm(rtrim(rtrim(fileURL, replace(fileURL, '/', '')), '/')),
                       0, 1, 64, 0
                FROM tracks
                WHERE aiAnalyzed = 1
                GROUP BY 2
                """)
        }

        return migrator
    }

    func fetchWantlist(states: [String]) throws -> [WantlistRecord] {
        try dbQueue.read { db in
            try WantlistRecord
                .filter(states.contains(Column("state")))
                .order(Column("score").desc, Column("addedAt").desc)
                .fetchAll(db)
        }
    }

    /// Inserts unseen suggestions and refreshes still-wanted ones; rows the
    /// user has dismissed or acquired are left untouched so a suggestion can
    /// never resurrect itself.
    func mergeWantlistSuggestions(_ records: [WantlistRecord]) throws {
        try dbQueue.write { db in
            for record in records {
                if var existing = try WantlistRecord.filter(Column("normKey") == record.normKey).fetchOne(db) {
                    guard existing.state == WantlistState.wanted.rawValue else { continue }
                    existing.score = record.score
                    existing.reason = record.reason
                    existing.playCount = record.playCount
                    if existing.imageURL == nil { existing.imageURL = record.imageURL }
                    try existing.update(db)
                } else {
                    try record.insert(db)
                }
            }
        }
    }

    func updateWantlistState(normKey: String, state: String, resolvedAt: Date?) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE wantlist SET state = ?, resolvedAt = ? WHERE normKey = ?",
                arguments: [state, resolvedAt, normKey]
            )
        }
    }

    func acknowledgeWantlist() throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE wantlist SET acknowledged = 1 WHERE acknowledged = 0")
        }
    }

    func unacknowledgedWantedCount() throws -> Int {
        try dbQueue.read { db in
            try WantlistRecord
                .filter(Column("state") == WantlistState.wanted.rawValue && Column("acknowledged") == false)
                .fetchCount(db)
        }
    }

    func replaceNewReleases(_ records: [NewReleaseRecord]) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM newReleaseCache")
            for record in records {
                try record.insert(db)
            }
        }
    }

    func fetchNewReleases() throws -> [NewReleaseRecord] {
        try dbQueue.read { db in
            try NewReleaseRecord.order(Column("releaseDate").desc).fetchAll(db)
        }
    }

    func newReleasesFetchedAt() throws -> Date? {
        try dbQueue.read { db in
            try Date.fetchOne(db, sql: "SELECT MAX(fetchedAt) FROM newReleaseCache")
        }
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

    /// Updates a track fetched without its artwork BLOB, leaving the stored
    /// `artworkData` column untouched.
    func updateTrackPreservingArtwork(_ track: TrackRecord) throws {
        try dbQueue.write { db in
            try track.update(db, columns: Self.trackColumnsWithoutArtwork)
        }
    }

    /// Inserts each row independently inside the batch transaction so one
    /// conflicting row (e.g. a duplicate fileURL from a concurrent import)
    /// never rolls back the other tracks in the batch. Embedded artwork is
    /// hoisted into `albumInfo` once per album rather than duplicated on every
    /// track row, which is what lets the enrichment queue see that an album
    /// already has a cover and skip it.
    func insertTracks(_ tracks: [TrackRecord]) throws {
        guard !tracks.isEmpty else { return }
        try dbQueue.write { db in
            for track in tracks {
                do {
                    try Self.hoistingCoverArt(track, in: db).insert(db)
                } catch {
                    AppLogger.error("Skipped track insert for \(track.fileURL): \(error.localizedDescription)", category: .database)
                }
            }
        }
    }

    /// Moves a track's embedded artwork to its album and returns the row to
    /// store. A track with no album title keeps its own artwork, since there is
    /// no album row that could hold it — the same rule migration v10 applies.
    private static func hoistingCoverArt(_ track: TrackRecord, in db: Database) throws -> TrackRecord {
        guard !track.albumTitle.isEmpty, let artwork = track.artworkData else { return track }
        try saveAlbumCoverArtIfMissing(title: track.albumTitle, artist: track.artist, data: artwork, in: db)
        var stripped = track
        stripped.artworkData = nil
        return stripped
    }

    /// Fetches every track without the artwork BLOB column so full-library reads stay lean;
    /// `artworkData` decodes as nil. Use `fetchAlbumArtwork(title:artist:)` for images.
    func fetchAllTracks() throws -> [TrackRecord] {
        try dbQueue.read { db in
            try TrackRecord.fetchAll(db, TrackRecord.select(Self.trackColumnsWithoutArtwork))
        }
    }

    private static let trackColumnsWithoutArtwork: [Column] = [
        Column("id"), Column("fileURL"), Column("title"), Column("artist"),
        Column("albumTitle"), Column("trackNumber"), Column("duration"),
        Column("lastFMArtworkURL"), Column("musicBrainzID"), Column("albumMusicBrainzID"),
        Column("dateAdded"), Column("lastPlayed"), Column("playCount"),
        Column("aiAnalyzed"), Column("analysisAttemptedAt"),
        Column("codec"), Column("bitDepth"), Column("sampleRate"), Column("channels"),
        Column("loved"), Column("lovedPendingOp"),
    ]

    func fetchAllTrackRelativePaths() throws -> Set<String> {
        try dbQueue.read { db in
            let paths = try String.fetchAll(db, sql: "SELECT fileURL FROM tracks")
            return Set(paths)
        }
    }

    func fetchTrackSortKeys() throws -> [(fileURL: String, lastPlayed: Date?)] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT fileURL, lastPlayed FROM tracks")
            return rows.map { (fileURL: $0["fileURL"], lastPlayed: $0["lastPlayed"]) }
        }
    }

    func fetchTrack(byRelativePath path: String) throws -> TrackRecord? {
        try dbQueue.read { db in
            try TrackRecord.filter(Column("fileURL") == path).fetchOne(db)
        }
    }

    func deleteTrack(id: Int64) throws {
        try dbQueue.write { db in
            if let fileURL = try String.fetchOne(db, sql: "SELECT fileURL FROM tracks WHERE id = ?", arguments: [id]) {
                _ = try PlaylistTrackRecord.filter(Column("trackFileURL") == fileURL).deleteAll(db)
            }
            _ = try TrackRecord.deleteOne(db, id: id)
        }
    }

    func deleteTracksNotIn(relativePaths: Set<String>) throws {
        try dbQueue.write { db in
            if relativePaths.isEmpty {
                _ = try PlaylistTrackRecord.deleteAll(db)
                _ = try TrackRecord.deleteAll(db)
            } else {
                _ = try PlaylistTrackRecord.filter(!relativePaths.contains(Column("trackFileURL"))).deleteAll(db)
                _ = try TrackRecord.filter(!relativePaths.contains(Column("fileURL"))).deleteAll(db)
            }
            try Self.sweepOrphanedAlbumEnrichment(in: db)
        }
    }

    /// Drops enrichment state for albums the library no longer contains, for
    /// callers that retitle without deleting a track — an AI identification
    /// pass rewrites `albumTitle`/`artist`, which changes the key, so the old
    /// one would otherwise keep its exhausted verdict and keep inflating the
    /// report's "Gave up" count forever. Run it once per batch: it is a
    /// full-table anti-join, not per-row work.
    func sweepOrphanedAlbumEnrichment() throws {
        try dbQueue.write { db in try Self.sweepOrphanedAlbumEnrichment(in: db) }
    }

    /// Drops enrichment state for albums the library no longer contains, in the
    /// same transaction as the track delete so the two can never disagree. An
    /// AI retitle changes the key, so the renamed album arrives as a new pending
    /// entity instead of inheriting the old one's exhausted verdict.
    private static func sweepOrphanedAlbumEnrichment(in db: Database) throws {
        try db.execute(sql: """
            DELETE FROM enrichmentState
            WHERE scope = 'album'
              AND key NOT IN (
                  SELECT flaccy_norm(albumTitle) || char(31) || flaccy_norm(artist)
                  FROM tracks WHERE albumTitle <> ''
              )
            """)
    }

    func setPlayCount(relativePath: String, count: Int) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE tracks SET playCount = ? WHERE fileURL = ?", arguments: [count, relativePath])
        }
    }

    func rewriteAlbumTitle(from oldTitle: String, to newTitle: String, artist: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE tracks SET albumTitle = ? WHERE albumTitle = ? AND artist = ?", arguments: [newTitle, oldTitle, artist])
        }
    }

    /// Applies a whole library-hygiene plan in ONE transaction: album-info of
    /// each redundant variant is COALESCE-merged into the canonical album, the
    /// variant tracks are retitled, and each surviving duplicate keeper inherits
    /// the loved flag and highest play count of its group. File trashing happens
    /// outside this call (files can't participate in a DB transaction).
    func applyHygiene(
        retitles: [AlbumRetitle],
        keeperUpdates: [KeeperUpdate],
        albumInfoMerges: [AlbumInfoMerge],
        loserRelativePaths: [String]
    ) throws {
        try dbQueue.write { db in
            for path in loserRelativePaths {
                _ = try PlaylistTrackRecord.filter(Column("trackFileURL") == path).deleteAll(db)
                _ = try TrackRecord.filter(Column("fileURL") == path).deleteAll(db)
            }
            for merge in albumInfoMerges {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO albumInfo (title, artist) VALUES (?, ?)",
                    arguments: [merge.canonicalTitle, merge.canonicalArtist]
                )
                for variant in merge.variants where !(variant.title == merge.canonicalTitle && variant.artist == merge.canonicalArtist) {
                    try db.execute(sql: """
                        UPDATE albumInfo SET
                            coverArtURL = COALESCE(coverArtURL, (SELECT coverArtURL FROM albumInfo WHERE title = :vt AND artist = :va)),
                            coverArtData = COALESCE(coverArtData, (SELECT coverArtData FROM albumInfo WHERE title = :vt AND artist = :va)),
                            musicBrainzID = COALESCE(musicBrainzID, (SELECT musicBrainzID FROM albumInfo WHERE title = :vt AND artist = :va)),
                            year = COALESCE(year, (SELECT year FROM albumInfo WHERE title = :vt AND artist = :va)),
                            genre = COALESCE(genre, (SELECT genre FROM albumInfo WHERE title = :vt AND artist = :va)),
                            lastFetched = COALESCE(lastFetched, (SELECT lastFetched FROM albumInfo WHERE title = :vt AND artist = :va))
                        WHERE title = :ct AND artist = :ca
                    """, arguments: ["vt": variant.title, "va": variant.artist, "ct": merge.canonicalTitle, "ca": merge.canonicalArtist])
                    try db.execute(
                        sql: "DELETE FROM albumInfo WHERE title = ? AND artist = ?",
                        arguments: [variant.title, variant.artist]
                    )
                }
            }
            for retitle in retitles {
                try db.execute(
                    sql: "UPDATE tracks SET albumTitle = ?, artist = ? WHERE albumTitle = ? AND artist = ?",
                    arguments: [retitle.toTitle, retitle.toArtist, retitle.fromTitle, retitle.fromArtist]
                )
            }
            for update in keeperUpdates {
                try db.execute(
                    sql: "UPDATE tracks SET loved = ?, playCount = ? WHERE fileURL = ?",
                    arguments: [update.loved, update.playCount, update.relativePath]
                )
            }
            try Self.sweepOrphanedAlbumEnrichment(in: db)
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

    /// Stores album artwork once per album (first-writer-wins) instead of
    /// duplicating the BLOB on every track row.
    func saveAlbumCoverArtIfMissing(title: String, artist: String, data: Data) throws {
        try dbQueue.write { db in
            try Self.saveAlbumCoverArtIfMissing(title: title, artist: artist, data: data, in: db)
        }
    }

    private static func saveAlbumCoverArtIfMissing(title: String, artist: String, data: Data, in db: Database) throws {
        try db.execute(sql: """
            INSERT INTO albumInfo (title, artist, coverArtData) VALUES (?, ?, ?)
            ON CONFLICT(title, artist) DO UPDATE SET coverArtData = excluded.coverArtData
            WHERE albumInfo.coverArtData IS NULL
        """, arguments: [title, artist, data])
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

    /// Reports what an album is still missing without touching `coverArtData`,
    /// so deciding whether to enrich a thousand albums never pulls a thousand
    /// JPEGs through SQLite.
    func fetchAlbumInfoStatus(title: String, artist: String) throws -> (hasCover: Bool, year: String?, genre: String?, mbid: String?) {
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

    func fetchEnrichmentRecord(scope: EnrichmentScope, key: String) throws -> EnrichmentRecord? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM enrichmentState WHERE scope = ? AND key = ?",
                arguments: [scope.rawValue, key]
            ) else { return nil }
            return Self.enrichmentRecord(from: row, scope: scope)
        }
    }

    func upsertEnrichmentRecord(_ record: EnrichmentRecord) throws {
        try dbQueue.write { db in
            try Self.upsertEnrichmentRecord(record, in: db)
        }
    }

    /// Writes an album's newly-found metadata and the attempt's outcome in ONE
    /// transaction. Two separate writes with a crash between them would leave an
    /// album that is genuinely satisfied marked pending, costing a redundant
    /// attempt on the next launch. Every column fills only when it is still
    /// empty, and `lastFetched` is deliberately never stamped — all scheduling
    /// state lives in `enrichmentState` now.
    func applyAlbumEnrichment(
        title: String,
        artist: String,
        coverArtURL: String?,
        coverArtData: Data?,
        musicBrainzID: String?,
        year: String?,
        genre: String?,
        record: EnrichmentRecord
    ) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO albumInfo (title, artist, coverArtURL, coverArtData, musicBrainzID, year, genre)
                VALUES (:title, :artist, :coverArtURL, :coverArtData, :musicBrainzID, :year, :genre)
                ON CONFLICT(title, artist) DO UPDATE SET
                    coverArtURL = COALESCE(albumInfo.coverArtURL, excluded.coverArtURL),
                    coverArtData = COALESCE(albumInfo.coverArtData, excluded.coverArtData),
                    musicBrainzID = COALESCE(albumInfo.musicBrainzID, excluded.musicBrainzID),
                    year = COALESCE(albumInfo.year, excluded.year),
                    genre = COALESCE(albumInfo.genre, excluded.genre)
                """, arguments: [
                    "title": title,
                    "artist": artist,
                    "coverArtURL": coverArtURL,
                    "coverArtData": coverArtData,
                    "musicBrainzID": musicBrainzID,
                    "year": year,
                    "genre": genre,
                ])
            try Self.upsertEnrichmentRecord(record, in: db)
        }
    }

    /// The artist twin of `applyAlbumEnrichment`, with the same one-transaction
    /// and fill-missing-only guarantees.
    func applyArtistEnrichment(
        name: String,
        bio: String?,
        imageURL: String?,
        musicBrainzID: String?,
        record: EnrichmentRecord
    ) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO artists (name, bio, imageURL, musicBrainzID)
                VALUES (:name, :bio, :imageURL, :musicBrainzID)
                ON CONFLICT(name) DO UPDATE SET
                    bio = COALESCE(artists.bio, excluded.bio),
                    imageURL = COALESCE(artists.imageURL, excluded.imageURL),
                    musicBrainzID = COALESCE(artists.musicBrainzID, excluded.musicBrainzID)
                """, arguments: [
                    "name": name,
                    "bio": bio,
                    "imageURL": imageURL,
                    "musicBrainzID": musicBrainzID,
                ])
            try Self.upsertEnrichmentRecord(record, in: db)
        }
    }

    /// The albums the job should attempt next, in one SELECT that reads no BLOB
    /// column. Albums with no cover sort first because a coverless tile is the
    /// visible gap in the grid.
    func dueAlbumKeys(version: Int, now: Date, limit: Int) throws -> [(title: String, artist: String)] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT a.title, a.artist
                \(Self.albumDueSource)
                ORDER BY (i.coverArtData IS NULL) DESC, a.artist, a.title
                LIMIT :limit
                """, arguments: Self.dueArguments(scope: .album, version: version, now: now, limit: limit))
            return rows.map { (title: $0["title"], artist: $0["artist"]) }
        }
    }

    func dueArtistNames(version: Int, now: Date, limit: Int) throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT a.name
                \(Self.artistDueSource)
                ORDER BY a.name
                LIMIT :limit
                """, arguments: Self.dueArguments(scope: .artist, version: version, now: now, limit: limit))
        }
    }

    /// The directories still owed an AI identification pass, named exactly the
    /// way `Library` batches them: the parent path with no trailing slash, or
    /// the empty string for a track sitting at the library root.
    func dueAIBatchDirectories(version: Int, now: Date, limit: Int) throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT a.directory
                \(Self.aiBatchDueSource)
                ORDER BY a.directory
                LIMIT :limit
                """, arguments: Self.dueArguments(scope: .aiBatch, version: version, now: now, limit: limit))
        }
    }

    /// The `remaining` a job reports: a `count(*)` over the very predicate the
    /// queue drains, so the countdown is a fact about the database rather than
    /// a counter that can drift.
    func countDue(scope: EnrichmentScope, version: Int, now: Date) throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT count(*)
                \(Self.dueSource(for: scope))
                """, arguments: Self.dueArguments(scope: scope, version: version, now: now, limit: nil)) ?? 0
        }
    }

    func countExhausted(scope: EnrichmentScope) throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT count(*) FROM enrichmentState WHERE scope = ? AND status = ?",
                arguments: [scope.rawValue, EnrichmentStatus.exhausted.rawValue]
            ) ?? 0
        }
    }

    func exhaustedEntities(scope: EnrichmentScope) throws -> [EnrichmentRecord] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM enrichmentState
                WHERE scope = ? AND status = ?
                ORDER BY lastAttemptAt DESC, key
                """, arguments: [scope.rawValue, EnrichmentStatus.exhausted.rawValue])
            return rows.map { Self.enrichmentRecord(from: $0, scope: scope) }
        }
    }

    /// Requeues everything the job gave up on, keeping the fields already
    /// resolved so a retry only chases what is still missing. Returns how many
    /// entities were revived.
    @discardableResult
    func resetExhausted(scope: EnrichmentScope) throws -> Int {
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE enrichmentState
                SET status = ?, attempts = 0, nextEligibleAt = NULL, lastFailure = NULL
                WHERE scope = ? AND status = ?
                """, arguments: [
                    EnrichmentStatus.pending.rawValue,
                    scope.rawValue,
                    EnrichmentStatus.exhausted.rawValue,
                ])
            return db.changesCount
        }
    }

    func deleteAllEnrichmentState() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM enrichmentState")
        }
    }

    func libraryDebut() throws -> LibraryDebutSummary? {
        try dbQueue.read { db in
            guard let json = try String.fetchOne(db, sql: "SELECT summaryJSON FROM libraryDebut WHERE id = 1") else {
                return nil
            }
            do {
                return try Self.debutDecoder().decode(LibraryDebutSummary.self, from: Data(json.utf8))
            } catch {
                AppLogger.error("Library debut summary unreadable: \(error.localizedDescription)", category: .database)
                return nil
            }
        }
    }

    func saveLibraryDebut(_ summary: LibraryDebutSummary) throws {
        let json = String(decoding: try Self.debutEncoder().encode(summary), as: UTF8.self)
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO libraryDebut (id, completedAt, summaryJSON) VALUES (1, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    completedAt = excluded.completedAt,
                    summaryJSON = excluded.summaryJSON
                """, arguments: [summary.completedAt, json])
        }
    }

    func clearLibraryDebut() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM libraryDebut")
        }
    }

    private static func debutEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func debutDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func enrichmentRecord(from row: Row, scope: EnrichmentScope) -> EnrichmentRecord {
        let status: Int = row["status"]
        let fields: Int = row["fields"]
        let failure: String? = row["lastFailure"]
        return EnrichmentRecord(
            scope: scope,
            key: row["key"],
            version: row["version"],
            status: EnrichmentStatus(rawValue: status) ?? .pending,
            fields: EnrichmentFields(rawValue: fields),
            attempts: row["attempts"],
            lastAttemptAt: row["lastAttemptAt"],
            nextEligibleAt: row["nextEligibleAt"],
            lastFailure: failure.flatMap(EnrichmentFailure.init(rawValue:))
        )
    }

    private static func upsertEnrichmentRecord(_ record: EnrichmentRecord, in db: Database) throws {
        try db.execute(sql: """
            INSERT INTO enrichmentState
                (scope, key, version, status, fields, attempts, lastAttemptAt, nextEligibleAt, lastFailure)
            VALUES (:scope, :key, :version, :status, :fields, :attempts, :lastAttemptAt, :nextEligibleAt, :lastFailure)
            ON CONFLICT(scope, key) DO UPDATE SET
                version = excluded.version,
                status = excluded.status,
                fields = excluded.fields,
                attempts = excluded.attempts,
                lastAttemptAt = excluded.lastAttemptAt,
                nextEligibleAt = excluded.nextEligibleAt,
                lastFailure = excluded.lastFailure
            """, arguments: [
                "scope": record.scope.rawValue,
                "key": record.key,
                "version": record.version,
                "status": record.status.rawValue,
                "fields": record.fields.rawValue,
                "attempts": record.attempts,
                "lastAttemptAt": record.lastAttemptAt,
                "nextEligibleAt": record.nextEligibleAt,
                "lastFailure": record.lastFailure?.rawValue,
            ])
    }

    private static func dueArguments(scope: EnrichmentScope, version: Int, now: Date, limit: Int?) -> StatementArguments {
        var arguments: StatementArguments = [
            "requiredFields": EnrichmentFields.required(for: scope).rawValue,
            "version": version,
            "now": now,
        ]
        if let limit {
            arguments += ["limit": limit]
        }
        return arguments
    }

    private static func dueSource(for scope: EnrichmentScope) -> String {
        switch scope {
        case .album: return albumDueSource
        case .artist: return artistDueSource
        case .aiBatch: return aiBatchDueSource
        }
    }

    /// `EnrichmentPolicy.isDue` written as SQL, mirrored character for
    /// character by the Linux client. SQLite binds AND tighter than OR, so this
    /// reads as "there is no row at all, OR the required fields are still
    /// missing AND the ladder allows another attempt" — the same two-level
    /// shape as the Swift predicate.
    private static let dueClause = """
        e.key IS NULL
           OR (e.fields & :requiredFields) <> :requiredFields
          AND (
                e.status = 0
             OR e.status = 1
             OR (e.status = 2 AND e.version < :version)
             OR (e.status = 3 AND (e.version < :version OR e.nextEligibleAt IS NULL OR e.nextEligibleAt <= :now))
              )
        """

    private static let albumDueSource = """
        FROM (
            SELECT albumTitle AS title, artist FROM tracks WHERE albumTitle <> '' GROUP BY 1, 2
        ) a
        LEFT JOIN enrichmentState e
               ON e.scope = 'album'
              AND e.key = flaccy_norm(a.title) || char(31) || flaccy_norm(a.artist)
        LEFT JOIN albumInfo i
               ON i.title = a.title AND i.artist = a.artist
        WHERE \(DatabaseManager.dueClause)
        """

    private static let artistDueSource = """
        FROM (
            SELECT artist AS name FROM tracks WHERE artist <> '' GROUP BY 1
        ) a
        LEFT JOIN enrichmentState e
               ON e.scope = 'artist'
              AND e.key = flaccy_norm(a.name)
        WHERE \(DatabaseManager.dueClause)
        """

    /// The directory universe is deliberately narrowed to folders that still
    /// hold an unanalyzed track: a folder Flaccy has already been through is not
    /// work, whether or not migration v10 happened to seed a row for it.
    private static let aiBatchDueSource = """
        FROM (
            SELECT rtrim(rtrim(fileURL, replace(fileURL, '/', '')), '/') AS directory
            FROM tracks WHERE aiAnalyzed = 0 GROUP BY 1
        ) a
        LEFT JOIN enrichmentState e
               ON e.scope = 'aiBatch'
              AND e.key = flaccy_norm(a.directory)
        WHERE \(DatabaseManager.dueClause)
        """

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

    /// Retires pending scrobbles older than the cutoff by marking them submitted,
    /// keeping them as local listening history without queuing them for Last.fm,
    /// which rejects scrobbles more than 14 days old. Pass `.distantFuture` to
    /// retire the entire pending queue.
    func retirePendingScrobbles(olderThan cutoff: Date) throws {
        _ = try dbQueue.write { db in
            try ScrobbleRecord
                .filter(Column("submitted") == false && Column("timestamp") < cutoff)
                .updateAll(db, Column("submitted").set(to: true))
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

    /// Clears every track's analyzed flag and the per-directory verdicts that
    /// remember the batches were already identified, so a re-analysis is a real
    /// re-analysis rather than a queue that finds nothing due.
    func resetAllAIAnalyzed() throws {
        try dbQueue.write { db in
            _ = try TrackRecord
                .updateAll(db, Column("aiAnalyzed").set(to: false))
            try db.execute(
                sql: "DELETE FROM enrichmentState WHERE scope = ?",
                arguments: [EnrichmentScope.aiBatch.rawValue]
            )
        }
    }

    /// Backfills each track's play count and last-played time from the scrobble
    /// history (which includes imported Last.fm plays), so the Plays column and
    /// every play-based sort reflect a freshly imported history rather than only
    /// local playback.
    func reconcilePlayCountsFromScrobbles() throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE tracks SET
                    playCount = (SELECT COUNT(*) FROM scrobbles s WHERE s.trackTitle = tracks.title AND s.artist = tracks.artist),
                    lastPlayed = (SELECT MAX(s.timestamp) FROM scrobbles s WHERE s.trackTitle = tracks.title AND s.artist = tracks.artist)
                WHERE EXISTS (SELECT 1 FROM scrobbles s WHERE s.trackTitle = tracks.title AND s.artist = tracks.artist)
            """)
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

    /// Normalizes album+lead-artist into a grouping key so tracks whose titles
    /// differ only by case/punctuation, or whose ARTIST tags carry per-track
    /// featuring credits ("50 Cent Feat. Eminem"), still collapse into one album.
    static func albumGroupingKey(albumTitle: String, artist: String) -> String {
        func norm(_ s: String) -> String {
            s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }
        return "\(norm(albumTitle))\u{0}\(LibraryHygiene.artistKey(artist))"
    }

    /// Loads every album as a raw pressings-level group (exact album title +
    /// artist). Edition folding happens in `LibraryHygiene.consolidateAlbums`
    /// after these light records become `Track`s, so quality ranking and
    /// `duplicateKey` dedupe stay in one place shared with Linux.
    func fetchAlbumsWithTracksLightweight() throws -> [(album: AlbumInfoRecord?, tracks: [LightTrackRecord])] {
        try dbQueue.read { db in
            let columns: [Column] = [
                Column("id"), Column("fileURL"), Column("title"), Column("artist"),
                Column("albumTitle"), Column("trackNumber"), Column("duration"),
                Column("dateAdded"), Column("lastPlayed"), Column("playCount"),
                Column("loved"), Column("codec"), Column("bitDepth"),
                Column("sampleRate"), Column("channels"),
            ]

            let allTracks = try LightTrackRecord.fetchAll(db,
                TrackRecord.select(columns)
                    .order(Column("albumTitle").collating(.localizedCaseInsensitiveCompare).asc,
                           Column("artist").collating(.localizedCaseInsensitiveCompare).asc,
                           Column("trackNumber").asc,
                           Column("title").collating(.localizedCaseInsensitiveCompare).asc)
            )

            let allAlbumInfos = try Row.fetchAll(db, sql: """
                SELECT id, title, artist, coverArtURL, musicBrainzID, year, genre, lastFetched,
                       CASE WHEN coverArtData IS NOT NULL THEN 1 ELSE 0 END AS hasCoverArt
                FROM albumInfo
            """)
            var albumInfoByKey = [String: AlbumInfoRecord]()
            for row in allAlbumInfos {
                let info = AlbumInfoRecord(
                    id: row["id"],
                    title: row["title"],
                    artist: row["artist"],
                    coverArtURL: row["coverArtURL"],
                    coverArtData: nil,
                    musicBrainzID: row["musicBrainzID"],
                    year: row["year"],
                    genre: row["genre"],
                    lastFetched: row["lastFetched"]
                )
                let key = "\(info.title)\0\(info.artist)"
                albumInfoByKey[key] = info
            }

            var order: [String] = []
            var map: [String: [LightTrackRecord]] = [:]
            for track in allTracks {
                let groupKey = Self.albumGroupingKey(albumTitle: track.albumTitle, artist: track.artist)
                if map[groupKey] == nil { order.append(groupKey) }
                map[groupKey, default: []].append(track)
            }

            return order.compactMap { groupKey in
                guard let tracks = map[groupKey], !tracks.isEmpty else { return nil }
                let displayTitle = Self.majorityValue(tracks.map(\.albumTitle))
                let displayArtist = Self.majorityValue(tracks.map { LibraryHygiene.primaryArtist($0.artist) })
                let orderedTracks = TrackOrdering.ordered(
                    tracks,
                    number: { $0.trackNumber },
                    path: { $0.fileURL },
                    title: { $0.title }
                )
                let albumInfo = albumInfoByKey["\(displayTitle)\0\(displayArtist)"]
                    ?? tracks.lazy.compactMap { albumInfoByKey["\($0.albumTitle)\0\($0.artist)"] }.first
                return (album: albumInfo, tracks: orderedTracks)
            }
        }
    }

    private static func majorityValue(_ values: [String]) -> String {
        var counts: [String: Int] = [:]
        for value in values {
            counts[value, default: 0] += 1
        }
        return counts.max { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            return lhs.key.count > rhs.key.count
        }?.key ?? values[0]
    }

    /// Returns the larger of the enrichment cover and the embedded file artwork,
    /// since either source can be the low-resolution one for a given album.
    /// When the exact title misses (common after edition grouping folds a
    /// remaster into a deluxe card), falls back to the largest art among any
    /// album that shares the consolidation key.
    func fetchAlbumArtwork(title: String, artist: String) throws -> Data? {
        try dbQueue.read { db in
            if let exact = try Self.artworkPair(db: db, title: title, artist: artist) {
                return exact
            }
            let targetKey = LibraryHygiene.consolidationKey(title: title, artist: artist)
            let titles = try String.fetchAll(
                db,
                sql: "SELECT DISTINCT albumTitle FROM tracks WHERE artist = ?",
                arguments: [artist]
            )
            var best: Data?
            for variantTitle in titles {
                guard LibraryHygiene.consolidationKey(title: variantTitle, artist: artist) == targetKey else {
                    continue
                }
                guard let candidate = try Self.artworkPair(db: db, title: variantTitle, artist: artist) else {
                    continue
                }
                if best.map({ candidate.count > $0.count }) ?? true {
                    best = candidate
                }
            }
            return best
        }
    }

    private static func artworkPair(db: Database, title: String, artist: String) throws -> Data? {
        let cover: Data? = try Row.fetchOne(
            db,
            sql: "SELECT coverArtData FROM albumInfo WHERE title = ? AND artist = ? AND coverArtData IS NOT NULL",
            arguments: [title, artist]
        )?["coverArtData"]
        let embedded: Data? = try Row.fetchOne(
            db,
            sql: """
                SELECT artworkData FROM tracks
                WHERE albumTitle = ? AND artist = ? AND artworkData IS NOT NULL
                ORDER BY LENGTH(artworkData) DESC LIMIT 1
                """,
            arguments: [title, artist]
        )?["artworkData"]
        switch (cover, embedded) {
        case let (c?, e?): return e.count > c.count ? e : c
        case let (c?, nil): return c
        case let (nil, e?): return e
        default: return nil
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

            let allAlbumInfos = try AlbumInfoRecord.fetchAll(db)
            var albumInfoByKey = [String: AlbumInfoRecord]()
            for info in allAlbumInfos {
                albumInfoByKey["\(info.title)\0\(info.artist)"] = info
            }

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

            return grouped.compactMap { group in
                guard group.tracks.first != nil else { return nil }
                return (album: albumInfoByKey[group.key], tracks: group.tracks)
            }
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

    func fetchPlaylistTrackCounts() throws -> [Int64: Int] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT playlistId, COUNT(*) AS trackCount FROM playlistTracks GROUP BY playlistId")
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["playlistId"] as Int64, $0["trackCount"] as Int) })
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

    func findTrack(title: String, artist: String) throws -> TrackRecord? {
        try dbQueue.read { db in
            try TrackRecord
                .filter(Column("title").collating(.nocase) == title && Column("artist").collating(.nocase) == artist)
                .fetchOne(db)
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

    func fetchLyrics(trackTitle: String, artist: String) throws -> LyricsRecord? {
        try dbQueue.read { db in
            try LyricsRecord
                .filter(Column("trackTitle") == trackTitle && Column("artist") == artist)
                .fetchOne(db)
        }
    }

    func saveLyrics(_ record: LyricsRecord) throws {
        try dbQueue.write { db in
            try record.save(db)
        }
    }

    func setLoved(fileURL: String, loved: Bool, pendingOp: String?) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE tracks SET loved = ?, lovedPendingOp = ? WHERE fileURL = ?",
                arguments: [loved, pendingOp, fileURL]
            )
        }
    }

    func fetchLovedFileURLs() throws -> Set<String> {
        try dbQueue.read { db in
            Set(try String.fetchAll(db, sql: "SELECT fileURL FROM tracks WHERE loved = 1"))
        }
    }

    func fetchPendingLoveOps() throws -> [(fileURL: String, title: String, artist: String, op: String)] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT fileURL, title, artist, lovedPendingOp FROM tracks
                WHERE lovedPendingOp IS NOT NULL
            """)
            return rows.map { (fileURL: $0["fileURL"], title: $0["title"], artist: $0["artist"], op: $0["lovedPendingOp"]) }
        }
    }

    func clearPendingLoveOp(fileURL: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE tracks SET lovedPendingOp = NULL WHERE fileURL = ?", arguments: [fileURL])
        }
    }

    /// Applies a loved state matched by title+artist (used when syncing from
    /// Last.fm, which keys on names rather than file URLs).
    func markLoved(paths: [String], loved: Bool) throws {
        guard !paths.isEmpty else { return }
        try dbQueue.write { db in
            _ = try TrackRecord
                .filter(paths.contains(Column("fileURL")))
                .updateAll(db, Column("loved").set(to: loved))
        }
    }

    func fetchScrobbleTimestamps(since: Date) throws -> [Date] {
        try dbQueue.read { db in
            try Date.fetchAll(db, sql: "SELECT timestamp FROM scrobbles WHERE timestamp >= ? ORDER BY timestamp ASC", arguments: [since])
        }
    }

    func fetchScrobbleRows(from: Date, to: Date) throws -> [ScrobbleRecord] {
        try dbQueue.read { db in
            try ScrobbleRecord
                .filter(Column("timestamp") >= from && Column("timestamp") < to)
                .order(Column("timestamp").asc)
                .fetchAll(db)
        }
    }

    func scrobbleYears() throws -> [Int] {
        try dbQueue.read { db in
            try Int.fetchAll(db, sql: "SELECT DISTINCT CAST(strftime('%Y', timestamp) AS INTEGER) FROM scrobbles ORDER BY 1 DESC")
        }
    }

    func fetchAllScrobbleRows() throws -> [ScrobbleRecord] {
        try dbQueue.read { db in
            try ScrobbleRecord.order(Column("timestamp").asc).fetchAll(db)
        }
    }

    func playCountByTrack() throws -> [(trackTitle: String, artist: String, count: Int)] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT trackTitle, artist, COUNT(*) AS c FROM scrobbles
                GROUP BY trackTitle, artist
                ORDER BY c DESC
            """)
            return rows.map { (trackTitle: $0["trackTitle"], artist: $0["artist"], count: $0["c"]) }
        }
    }

    func lastPlayedByAlbum() throws -> [(albumTitle: String, artist: String, lastPlayed: Date, playCount: Int)] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT albumTitle, artist, MAX(timestamp) AS last, COUNT(*) AS c FROM scrobbles
                GROUP BY albumTitle, artist
            """)
            return rows.map { (albumTitle: $0["albumTitle"], artist: $0["artist"], lastPlayed: $0["last"], playCount: $0["c"]) }
        }
    }

    func scrobbleCountInRange(from: Date, to: Date) throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM scrobbles WHERE timestamp >= ? AND timestamp < ?", arguments: [from, to]) ?? 0
        }
    }

    func fetchLibraryArtists() throws -> Set<String> {
        try dbQueue.read { db in
            Set(try String.fetchAll(db, sql: "SELECT DISTINCT artist FROM tracks"))
        }
    }

    func fetchCachedSimilarArtists(artist: String, fresherThan: Date) throws -> [(similarName: String, match: Double)] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT similarName, match FROM similarArtistCache
                WHERE artist = ? AND fetchedAt >= ?
                ORDER BY match DESC
            """, arguments: [artist, fresherThan])
            return rows.map { (similarName: $0["similarName"], match: $0["match"]) }
        }
    }

    func saveSimilarArtists(artist: String, entries: [(name: String, match: Double)]) throws {
        try dbQueue.write { db in
            let now = Date()
            for entry in entries {
                try db.execute(sql: """
                    INSERT INTO similarArtistCache (artist, similarName, match, fetchedAt) VALUES (?, ?, ?, ?)
                    ON CONFLICT(artist, similarName) DO UPDATE SET match = excluded.match, fetchedAt = excluded.fetchedAt
                """, arguments: [artist, entry.name, entry.match, now])
            }
        }
    }

    func fetchWeeklyChart(chartType: String, fromUts: Int, toUts: Int) throws -> [WeeklyChartCacheRecord] {
        try dbQueue.read { db in
            try WeeklyChartCacheRecord
                .filter(Column("chartType") == chartType && Column("fromUts") == fromUts && Column("toUts") == toUts)
                .order(Column("rank").asc)
                .fetchAll(db)
        }
    }

    func saveWeeklyChart(_ records: [WeeklyChartCacheRecord]) throws {
        guard !records.isEmpty else { return }
        try dbQueue.write { db in
            for record in records {
                try record.insert(db)
            }
        }
    }
}
