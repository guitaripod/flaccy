import Foundation
import MidgarCore
import FlaccyCore
import GRDB

extension DatabaseManager {

    public func fetchEnrichmentRecord(scope: EnrichmentScope, key: String) throws -> EnrichmentRecord? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM enrichmentState WHERE scope = ? AND key = ?",
                arguments: [scope.rawValue, key]
            ) else { return nil }
            return Self.enrichmentRecord(from: row, scope: scope)
        }
    }

    public func upsertEnrichmentRecord(_ record: EnrichmentRecord) throws {
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
    public func applyAlbumEnrichment(
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
    public func applyArtistEnrichment(
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
    public func dueAlbumKeys(version: Int, now: Date, limit: Int) throws -> [(title: String, artist: String)] {
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

    public func dueArtistNames(version: Int, now: Date, limit: Int) throws -> [String] {
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
    public func dueAIBatchDirectories(version: Int, now: Date, limit: Int) throws -> [String] {
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
    public func countDue(scope: EnrichmentScope, version: Int, now: Date) throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT count(*)
                \(Self.dueSource(for: scope))
                """, arguments: Self.dueArguments(scope: scope, version: version, now: now, limit: nil)) ?? 0
        }
    }

    public func countExhausted(scope: EnrichmentScope) throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT count(*) FROM enrichmentState WHERE scope = ? AND status = ?",
                arguments: [scope.rawValue, EnrichmentStatus.exhausted.rawValue]
            ) ?? 0
        }
    }

    public func exhaustedEntities(scope: EnrichmentScope) throws -> [EnrichmentRecord] {
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
    public func resetExhausted(scope: EnrichmentScope) throws -> Int {
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

    public func deleteAllEnrichmentState() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM enrichmentState")
        }
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
            FROM tracks WHERE aiAnalyzed = 0 AND remoteServer IS NULL GROUP BY 1
        ) a
        LEFT JOIN enrichmentState e
               ON e.scope = 'aiBatch'
              AND e.key = flaccy_norm(a.directory)
        WHERE \(DatabaseManager.dueClause)
        """
}
