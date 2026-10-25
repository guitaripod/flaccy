import XCTest
@testable import FlaccyCore

/// Mirrored by the tests in `linux/shared/src/remote/remote_path.rs`: the same stored paths in both halves.
final class RemoteTrackPathTests: XCTestCase {

    func testRoundTripOfAPlainSongID() throws {
        let path = RemoteTrackPath(serverID: "srv-1", songID: "4vVKvXswBtHVzMYeWVqhKo").path

        XCTAssertEqual(path, "remote://srv-1/4vVKvXswBtHVzMYeWVqhKo")
        let parsed = try XCTUnwrap(RemoteTrackPath(path: path))
        XCTAssertEqual(parsed.serverID, "srv-1")
        XCTAssertEqual(parsed.songID, "4vVKvXswBtHVzMYeWVqhKo")
    }

    func testRoundTripOfASongIDWithSlashAndSpace() throws {
        let path = RemoteTrackPath(serverID: "srv-1", songID: "a/b c").path

        XCTAssertEqual(path, "remote://srv-1/a%2Fb%20c")
        XCTAssertEqual(RemoteTrackPath(path: path)?.songID, "a/b c")
    }

    func testMissingSongPartIsNotARemotePath() {
        XCTAssertNil(RemoteTrackPath(path: "remote://only"))
        XCTAssertNil(RemoteTrackPath(path: "remote:///song"))
        XCTAssertNil(RemoteTrackPath(path: "remote://srv/"))
    }

    func testLocalPathIsNotARemotePath() {
        XCTAssertNil(RemoteTrackPath(path: "Music/a.flac"))
        XCTAssertFalse(RemoteTrackPath.isRemote("Music/a.flac"))
        XCTAssertTrue(RemoteTrackPath.isRemote("remote://srv-1/a"))
    }
}
