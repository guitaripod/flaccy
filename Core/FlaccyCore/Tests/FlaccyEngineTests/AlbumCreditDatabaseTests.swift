import FlaccyCore
import GRDB
import XCTest
@testable import FlaccyEngine

/// The credit pass over a real database: compilations adopt the covers their
/// tracks hoisted, and a settled library is resolved without a write. Mirrors
/// the adoption tests in `linux/library/src/db.rs`; the app target's
/// `DatabaseManagerCreditTests` covers how credits resolve.
final class AlbumCreditDatabaseTests: XCTestCase {

    private var directory: URL!
    private var db: DatabaseManager!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("flaccy-credits-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        db = try DatabaseManager(path: directory.appendingPathComponent("library.sqlite").path)
    }

    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func insert(_ path: String, artist: String, album: String) throws {
        try db.insertTrack(TrackRecord(
            fileURL: path, title: path, artist: artist, albumTitle: album, trackNumber: 1,
            duration: 200, dateAdded: Date(), playCount: 0, aiAnalyzed: false, codec: "FLAC"
        ))
    }

    private func totalChanges() throws -> Int {
        try db.dbQueue.read { $0.totalChangesCount }
    }

    func testACreditedReleaseAdoptsTheCoverItsTracksHoisted() throws {
        for (index, artist) in ["Composer A", "Composer B", "Composer C", "Composer D"].enumerated() {
            try insert("Score/\(index).flac", artist: artist, album: "Score")
        }
        try db.saveAlbumCoverArtIfMissing(title: "Score", artist: "Composer B", data: Data([1, 2, 3]))
        XCTAssertNil(try db.fetchAlbumArtwork(title: "Score", artist: AlbumCredit.variousArtists))

        XCTAssertEqual(try db.resolveAlbumCredits(), 4)

        XCTAssertEqual(try db.fetchAlbumArtwork(title: "Score", artist: AlbumCredit.variousArtists), Data([1, 2, 3]))
    }

    func testASettledLibraryIsResolvedWithoutWriting() throws {
        for (index, artist) in ["Composer A", "Composer B"].enumerated() {
            try insert("Score/\(index).flac", artist: artist, album: "Score")
        }
        try insert("Solo/0.flac", artist: "Solo Artist", album: "Solo")
        try db.saveAlbumCoverArtIfMissing(title: "Score", artist: "Composer A", data: Data([1]))
        try db.saveAlbumCoverArtIfMissing(title: "Solo", artist: "Solo Artist", data: Data([7]))
        try db.resolveAlbumCredits()

        let before = try totalChanges()
        XCTAssertEqual(try db.resolveAlbumCredits(), 0)
        XCTAssertEqual(try totalChanges(), before)
        XCTAssertEqual(try db.fetchAlbumArtwork(title: "Score", artist: AlbumCredit.variousArtists), Data([1]))
    }

    func testAdoptionNeverOverwritesACoverTheCreditAlreadyHas() throws {
        for (index, artist) in ["Composer A", "Composer B"].enumerated() {
            try insert("Score/\(index).flac", artist: artist, album: "Score")
        }
        try db.saveAlbumCoverArtIfMissing(title: "Score", artist: AlbumCredit.variousArtists, data: Data([5]))
        try db.saveAlbumCoverArtIfMissing(title: "Score", artist: "Composer A", data: Data([1]))

        XCTAssertEqual(try db.resolveAlbumCredits(), 2)
        XCTAssertEqual(try db.resolveAlbumCredits(), 0)

        XCTAssertEqual(try db.fetchAlbumArtwork(title: "Score", artist: AlbumCredit.variousArtists), Data([5]))
    }
}
