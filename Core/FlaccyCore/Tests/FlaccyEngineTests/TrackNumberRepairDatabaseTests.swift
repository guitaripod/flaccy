import FlaccyCore
import GRDB
import XCTest
@testable import FlaccyEngine

/// The track number repair's two database steps: which songs it re-reads and
/// that it only fills a number that is still missing.
final class TrackNumberRepairDatabaseTests: XCTestCase {

    private var directory: URL!
    private var db: DatabaseManager!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("flaccy-track-numbers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        db = try DatabaseManager(path: directory.appendingPathComponent("library.sqlite").path)
    }

    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func insert(_ path: String, number: Int, remoteServer: String? = nil) throws {
        var record = TrackRecord(
            fileURL: path, title: path, artist: "Artist", albumTitle: "Album", trackNumber: number,
            duration: 200, dateAdded: Date(), playCount: 0, aiAnalyzed: false, codec: "MP3"
        )
        record.remoteServer = remoteServer
        try db.insertTrack(record)
    }

    private func number(of path: String) throws -> Int? {
        try db.dbQueue.read { try Int.fetchOne($0, sql: "SELECT trackNumber FROM tracks WHERE fileURL = ?", arguments: [path]) }
    }

    func testOnlyLocalSongsWithoutANumberAreReRead() throws {
        try insert("Album/b.mp3", number: 0)
        try insert("Album/a.m4a", number: 0)
        try insert("Album/c.mp3", number: 3)
        try insert("remote://server/song", number: 0, remoteServer: "server")

        XCTAssertEqual(try db.fetchLocalPathsWithoutTrackNumber(), ["Album/a.m4a", "Album/b.mp3"])
    }

    func testFillingWritesOnlyNumbersStillMissing() throws {
        try insert("Album/a.mp3", number: 0)
        try insert("Album/b.mp3", number: 5)

        XCTAssertEqual(try db.fillMissingTrackNumbers(["Album/a.mp3": 2, "Album/b.mp3": 9, "Album/gone.mp3": 1]), 1)

        XCTAssertEqual(try number(of: "Album/a.mp3"), 2)
        XCTAssertEqual(try number(of: "Album/b.mp3"), 5)
        XCTAssertEqual(try db.fetchLocalPathsWithoutTrackNumber(), [])
    }

    func testNothingFoundWritesNothing() throws {
        try insert("Album/a.mp3", number: 0)

        XCTAssertEqual(try db.fillMissingTrackNumbers([:]), 0)
        XCTAssertEqual(try db.fillMissingTrackNumbers(["Album/a.mp3": 0]), 0)
        XCTAssertEqual(try number(of: "Album/a.mp3"), 0)
    }
}
