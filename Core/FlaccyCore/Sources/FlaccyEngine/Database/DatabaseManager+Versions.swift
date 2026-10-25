import Foundation
import MidgarCore
import FlaccyCore
import GRDB

/// A replaced file kept aside: where the song's file lived, where the version it
/// replaced was moved to (relative to the previous-versions folder), and when.
public struct PreviousVersionRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {

    public static let databaseTableName = "previousVersions"

    public var trackFileURL: String
    public var storedPath: String
    public var movedAt: Date

    public init(trackFileURL: String, storedPath: String, movedAt: Date) {
        self.trackFileURL = trackFileURL
        self.storedPath = storedPath
        self.movedAt = movedAt
    }
}

/// What a fresh read of a file's tags says about its track row.
///
/// The technical fields always replace what is stored. The descriptive ones
/// replace it only while the row has not been through the AI cleanup, whose
/// answers are better than the tags it started from.
public struct TrackMetadataRefresh: Sendable {
    public var title: String
    public var artist: String
    public var albumTitle: String
    public var albumArtist: String?
    public var trackNumber: Int
    public var duration: Double
    public var artworkData: Data?
    public var codec: String?
    public var bitDepth: Int?
    public var sampleRate: Int?
    public var channels: Int?

    public init(
        title: String,
        artist: String,
        albumTitle: String,
        albumArtist: String?,
        trackNumber: Int,
        duration: Double,
        artworkData: Data?,
        codec: String?,
        bitDepth: Int?,
        sampleRate: Int?,
        channels: Int?
    ) {
        self.title = title
        self.artist = artist
        self.albumTitle = albumTitle
        self.albumArtist = albumArtist
        self.trackNumber = trackNumber
        self.duration = duration
        self.artworkData = artworkData
        self.codec = codec
        self.bitDepth = bitDepth
        self.sampleRate = sampleRate
        self.channels = channels
    }
}

extension DatabaseManager {

    /// Every track's version facts keyed by its relative path, in one read.
    public func fetchStoredVersions() throws -> [String: StoredVersion] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT fileURL, fileSize, fileModifiedMs, audioFingerprint, revision, revisedAt FROM tracks
                """)
            var versions: [String: StoredVersion] = [:]
            versions.reserveCapacity(rows.count)
            for row in rows {
                versions[row["fileURL"]] = Self.storedVersion(from: row)
            }
            return versions
        }
    }

    public func fetchStoredVersion(relativePath: String) throws -> StoredVersion? {
        try dbQueue.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT fileURL, fileSize, fileModifiedMs, audioFingerprint, revision, revisedAt
                FROM tracks WHERE fileURL = ?
                """, arguments: [relativePath])
            return row.map(Self.storedVersion(from:))
        }
    }

    private static func storedVersion(from row: Row) -> StoredVersion {
        let size: Int64? = row["fileSize"]
        let modified: Int64? = row["fileModifiedMs"]
        let signature: FileSignature? = if let size, let modified {
            FileSignature(size: size, modifiedMilliseconds: modified)
        } else {
            nil
        }
        return StoredVersion(
            signature: signature,
            fingerprint: row["audioFingerprint"],
            revision: row["revision"] ?? 1,
            revisedAt: row["revisedAt"]
        )
    }

    /// Stores one path's signature, fingerprint and revision.
    public func updateVersion(relativePath: String, _ version: StoredVersion) throws {
        try dbQueue.write { db in
            try Self.writeVersion(version, relativePath: relativePath, in: db)
        }
    }

    /// Stores many paths' versions in one transaction, for the first scan that
    /// baselines a whole library.
    public func updateVersions(_ updates: [(relativePath: String, version: StoredVersion)]) throws {
        guard !updates.isEmpty else { return }
        try dbQueue.write { db in
            for update in updates {
                try Self.writeVersion(update.version, relativePath: update.relativePath, in: db)
            }
        }
    }

    private static func writeVersion(_ version: StoredVersion, relativePath: String, in db: Database) throws {
        let values: [(any DatabaseValueConvertible)?] = [
            version.signature?.size,
            version.signature?.modifiedMilliseconds,
            version.fingerprint,
            version.revision,
            version.revisedAt,
            relativePath,
        ]
        try db.execute(sql: """
            UPDATE tracks SET
                fileSize = ?, fileModifiedMs = ?, audioFingerprint = ?, revision = ?, revisedAt = ?
            WHERE fileURL = ?
            """, arguments: StatementArguments(values))
    }

    /// Re-reads one track's metadata into its existing row, never deleting and
    /// inserting, so the row keeps its id, its playlist places, its play count
    /// and its love. Embedded art goes through the same album-level hoist an
    /// insert uses, and the orphan sweep drops enrichment state for an album
    /// the new tags no longer name. `storing` lands in the same transaction.
    /// Returns false when no row has that path.
    @discardableResult
    public func refreshMetadata(
        relativePath: String,
        with refresh: TrackMetadataRefresh,
        storing version: StoredVersion? = nil
    ) throws -> Bool {
        try dbQueue.write { db in
            guard let current = try Row.fetchOne(
                db,
                sql: "SELECT aiAnalyzed, albumTitle, artist FROM tracks WHERE fileURL = ?",
                arguments: [relativePath]
            ) else { return false }
            let isAIAnalyzed: Bool = current["aiAnalyzed"]
            try Self.writeTechnicalFields(of: refresh, relativePath: relativePath, in: db)
            var albumTitle: String = current["albumTitle"]
            var artist: String = current["artist"]
            if !isAIAnalyzed {
                try Self.writeDescriptiveFields(of: refresh, relativePath: relativePath, in: db)
                albumTitle = refresh.albumTitle
                artist = refresh.artist
            }
            try Self.hoistRefreshedArt(refresh.artworkData, relativePath: relativePath, albumTitle: albumTitle, artist: artist, in: db)
            if let version {
                try Self.writeVersion(version, relativePath: relativePath, in: db)
            }
            try Self.sweepOrphanedAlbumEnrichment(in: db)
            return true
        }
    }

    private static func writeTechnicalFields(of refresh: TrackMetadataRefresh, relativePath: String, in db: Database) throws {
        let values: [(any DatabaseValueConvertible)?] = [
            refresh.duration, refresh.codec, refresh.bitDepth, refresh.sampleRate, refresh.channels, relativePath,
        ]
        try db.execute(sql: """
            UPDATE tracks SET duration = ?, codec = ?, bitDepth = ?, sampleRate = ?, channels = ?
            WHERE fileURL = ?
            """, arguments: StatementArguments(values))
    }

    private static func writeDescriptiveFields(of refresh: TrackMetadataRefresh, relativePath: String, in db: Database) throws {
        let values: [(any DatabaseValueConvertible)?] = [
            refresh.title, refresh.artist, refresh.albumTitle, refresh.albumArtist, refresh.trackNumber, relativePath,
        ]
        try db.execute(sql: """
            UPDATE tracks SET title = ?, artist = ?, albumTitle = ?, albumArtist = ?, trackNumber = ?
            WHERE fileURL = ?
            """, arguments: StatementArguments(values))
    }

    private static func hoistRefreshedArt(
        _ artwork: Data?, relativePath: String, albumTitle: String, artist: String, in db: Database
    ) throws {
        guard let artwork else { return }
        if albumTitle.isEmpty {
            try db.execute(
                sql: "UPDATE tracks SET artworkData = ? WHERE fileURL = ?",
                arguments: [artwork, relativePath]
            )
        } else {
            try saveAlbumCoverArtIfMissing(title: albumTitle, artist: artist, data: artwork, in: db)
        }
    }

    public func upsertPreviousVersion(_ record: PreviousVersionRecord) throws {
        try dbQueue.write { db in
            try record.save(db)
        }
    }

    public func fetchPreviousVersion(trackFileURL: String) throws -> PreviousVersionRecord? {
        try dbQueue.read { db in
            try PreviousVersionRecord.fetchOne(db, key: trackFileURL)
        }
    }

    public func hasPreviousVersion(trackFileURL: String) -> Bool {
        (try? fetchPreviousVersion(trackFileURL: trackFileURL)) != nil
    }

    public func deletePreviousVersion(trackFileURL: String) throws {
        try dbQueue.write { db in
            _ = try PreviousVersionRecord.deleteOne(db, key: trackFileURL)
        }
    }

    /// The previous versions older than the retention period at `now`.
    public func fetchExpiredPreviousVersions(now: Date) throws -> [PreviousVersionRecord] {
        try dbQueue.read { db in
            try PreviousVersionRecord.fetchAll(db).filter {
                TrackRevision.previousVersionExpired(movedAt: $0.movedAt, now: now)
            }
        }
    }
}
