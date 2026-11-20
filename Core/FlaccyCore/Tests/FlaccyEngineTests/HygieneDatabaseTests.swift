import FlaccyCore
import GRDB
import XCTest
@testable import FlaccyEngine

/// Clean Up Library fuses an album's editions in the library folder and leaves a server's songs filed as the server
/// files them, since the next sync would undo a rewrite of a server's row anyway.
final class HygieneDatabaseTests: XCTestCase {

    private var directory: URL!
    private var db: DatabaseManager!
    private let server = "home"
    private let deluxe = "Aurora (Deluxe Edition)"

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("flaccy-hygiene-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        db = try DatabaseManager(path: directory.appendingPathComponent("library.sqlite").path)
        try db.saveRemoteServer(RemoteServerRecord(
            id: server, name: "arch", baseURL: "http://arch:4545", username: "", authKind: .apiKey,
            addedAt: Date(timeIntervalSince1970: 1_800_000_000)
        ))
    }

    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func insert(_ path: String, remote: Bool) throws {
        var record = TrackRecord(
            fileURL: path, title: "Opening", artist: "Aurora Band", albumTitle: deluxe, trackNumber: 1, duration: 200,
            dateAdded: Date(timeIntervalSince1970: 1_700_000_000), playCount: 0, aiAnalyzed: false, codec: "FLAC"
        )
        if remote {
            record.remoteServer = server
            record.remoteSuffix = "flac"
        }
        try db.insertTrack(record)
    }

    private func album(of path: String) throws -> String? {
        try db.dbQueue.read { try TrackRecord.filter(Column("fileURL") == path).fetchOne($0)?.albumTitle }
    }

    func testEditionRetitlesLeaveServerSongsAlone() throws {
        let serverPath = RemoteTrackPath(serverID: server, songID: "s1").path
        try insert("aurora-deluxe/01.flac", remote: false)
        try insert(serverPath, remote: true)
        try db.applyHygiene(
            retitles: [AlbumRetitle(fromTitle: deluxe, fromArtist: "Aurora Band", toTitle: "Aurora", toArtist: "Aurora Band")],
            keeperUpdates: [],
            albumInfoMerges: [],
            loserRelativePaths: []
        )
        XCTAssertEqual(try album(of: "aurora-deluxe/01.flac"), "Aurora")
        XCTAssertEqual(try album(of: serverPath), deluxe)
    }
}
