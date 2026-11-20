import FlaccyCore
import GRDB
import XCTest
@testable import FlaccyEngine

/// What an identification pass writes: the tags it read, and nothing a person changed while it waited for its answer.
final class IdentificationDatabaseTests: XCTestCase {

    private var directory: URL!
    private var db: DatabaseManager!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("flaccy-identification-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        db = try DatabaseManager(path: directory.appendingPathComponent("library.sqlite").path)
    }

    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(at: directory)
    }

    func testALoveAndAPlayMadeWhileThePassWaitedSurvive() throws {
        let track = try db.insertTrack(TrackRecord(
            fileURL: "Album/01 - song.m4a", title: "01 - song", artist: "Unknown Artist", albumTitle: "Album",
            trackNumber: 0, duration: 200, dateAdded: Date(), playCount: 0, aiAnalyzed: false
        ))
        try db.setLoved(fileURL: track.fileURL, loved: true, pendingOp: nil)
        try db.incrementPlayCount(trackId: try XCTUnwrap(track.id))

        XCTAssertTrue(try db.applyIdentification(
            fileURL: track.fileURL, title: "Song", artist: "Artist", albumTitle: "Album", trackNumber: 1
        ))

        let stored = try XCTUnwrap(try db.fetchTrack(byRelativePath: track.fileURL))
        XCTAssertEqual(stored.title, "Song")
        XCTAssertEqual(stored.artist, "Artist")
        XCTAssertEqual(stored.trackNumber, 1)
        XCTAssertTrue(stored.aiAnalyzed)
        XCTAssertTrue(stored.loved)
        XCTAssertEqual(stored.playCount, 1)
    }

    func testARowThatLeftOrMovedToAServerIsNotWritten() throws {
        XCTAssertFalse(try db.applyIdentification(
            fileURL: "Album/gone.m4a", title: "Song", artist: "Artist", albumTitle: "Album", trackNumber: 1
        ))
        var remote = TrackRecord(
            fileURL: "remote://srv/s1", title: "Song", artist: "Artist", albumTitle: "Album", trackNumber: 1,
            duration: 200, dateAdded: Date(), playCount: 0, aiAnalyzed: true
        )
        remote.remoteServer = "srv"
        try db.insertTrack(remote)
        XCTAssertFalse(try db.applyIdentification(
            fileURL: "remote://srv/s1", title: "Other", artist: "Artist", albumTitle: "Album", trackNumber: 1
        ))
    }
}
