import FlaccyCore
import GRDB
import XCTest
@testable import flaccy

/// Migration v10 is the one migration that reads the library it is migrating:
/// it classifies every album and artist the app already had into the durable
/// queue, and hoists embedded artwork out of `tracks` and into `albumInfo`. A
/// mis-derived key or a re-run seed is invisible at runtime — the library simply
/// enriches itself all over again — so the only place it can be caught is here,
/// against a fixture opened at v9 and migrated by the shipping migrator.
nonisolated final class DatabaseMigrationTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("flaccy-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testMigrationV10SeedsSatisfiedForCoverAndYear() throws {
        let path = try seedV9 { db in
            try db.execute(sql: """
                INSERT INTO albumInfo (title, artist, coverArtData, year, genre)
                VALUES ('Ágætis byrjun', 'Sigur Rós', x'00', '1999', 'Post-rock')
                """)
            try db.execute(sql: """
                INSERT INTO albumInfo (title, artist) VALUES ('Untitled', 'Nobody')
                """)
        }

        let manager = try DatabaseManager(path: path)
        let settled = try XCTUnwrap(manager.fetchEnrichmentRecord(
            scope: .album, key: EnrichmentKey.album(title: "Ágætis byrjun", artist: "Sigur Rós")
        ))
        XCTAssertEqual(settled.status, .satisfied)
        XCTAssertTrue(settled.fields.contains(.cover))
        XCTAssertTrue(settled.fields.contains(.year))
        XCTAssertFalse(EnrichmentPolicy.isDue(settled, scope: .album, now: Date()))

        let pending = try XCTUnwrap(manager.fetchEnrichmentRecord(
            scope: .album, key: EnrichmentKey.album(title: "Untitled", artist: "Nobody")
        ))
        XCTAssertEqual(pending.status, .pending)
        XCTAssertTrue(EnrichmentPolicy.isDue(pending, scope: .album, now: Date()))
    }

    func testMigrationV10HoistsEmbeddedArtworkIntoAlbumInfo() throws {
        let path = try seedV9 { db in
            try db.execute(sql: """
                INSERT INTO tracks
                    (fileURL, title, artist, albumTitle, trackNumber, duration, artworkData, dateAdded)
                VALUES ('a/1.flac', 'One', 'Sigur Rós', 'Ágætis byrjun', 1, 100.0, x'0102', 0)
                """)
        }

        let manager = try DatabaseManager(path: path)
        let status = try manager.fetchAlbumInfoStatus(title: "Ágætis byrjun", artist: "Sigur Rós")
        XCTAssertTrue(status.hasCover, "the cover moved out of the track row")

        let track = try XCTUnwrap(manager.fetchTrack(byRelativePath: "a/1.flac"))
        XCTAssertNil(track.artworkData, "a track row never carries a second copy of the cover")
    }

    func testMigrationV10IsIdempotentAcrossReopen() throws {
        let path = try seedV9 { db in
            try db.execute(sql: """
                INSERT INTO albumInfo (title, artist, coverArtData, year)
                VALUES ('Ágætis byrjun', 'Sigur Rós', x'00', '1999')
                """)
        }

        let first = try DatabaseManager(path: path)
        let key = EnrichmentKey.album(title: "Ágætis byrjun", artist: "Sigur Rós")
        var record = try XCTUnwrap(first.fetchEnrichmentRecord(scope: .album, key: key))
        record.attempts = 3
        record.status = .exhausted
        try first.upsertEnrichmentRecord(record)

        let second = try DatabaseManager(path: path)
        let reopened = try XCTUnwrap(second.fetchEnrichmentRecord(scope: .album, key: key))
        XCTAssertEqual(reopened.attempts, 3, "reopening must not re-run the seed over live state")
        XCTAssertEqual(reopened.status, .exhausted)
    }

    /// A database carrying the schema the app shipped before the enrichment
    /// queue existed, with whatever `seed` puts in it, closed and left on disk
    /// for the real migrator to find.
    private func seedV9(_ seed: (Database) throws -> Void) throws -> String {
        let path = directory.appendingPathComponent("library.sqlite").path
        let queue = try DatabaseQueue(path: path)
        try DatabaseManager.migrator().migrate(queue, upTo: "v9")
        try queue.write { db in try seed(db) }
        try queue.close()
        return path
    }
}
