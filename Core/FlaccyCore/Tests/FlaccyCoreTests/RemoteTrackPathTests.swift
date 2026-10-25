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

    func testAssetURLSharesTheStoredPathsEscaping() throws {
        let song = RemoteTrackPath(serverID: "srv-1", songID: "a/b c")

        XCTAssertEqual(song.assetURL.absoluteString, "flaccy-remote://srv-1/a%2Fb%20c")
        XCTAssertEqual(RemoteTrackPath(assetURL: song.assetURL), song)
    }

    func testAssetURLKeepsAnUppercaseServerID() throws {
        let song = RemoteTrackPath(serverID: "E621E1F8-C36C-495A-93FC-0C247A3E6E5B", songID: "4vVKvXswBtHVzMYeWVqhKo")

        let parsed = try XCTUnwrap(RemoteTrackPath(assetURL: song.assetURL))
        XCTAssertEqual(parsed.serverID, "E621E1F8-C36C-495A-93FC-0C247A3E6E5B")
        XCTAssertEqual(parsed.path, song.path)
    }

    func testOnlyARemoteAssetURLParses() {
        XCTAssertNil(RemoteTrackPath(assetURL: URL(fileURLWithPath: "/tmp/a.flac")))
        XCTAssertNil(RemoteTrackPath(assetURL: URL(string: "flaccy-remote://only")!))
        XCTAssertNil(RemoteTrackPath(assetURL: URL(string: "https://srv/song")!))
        XCTAssertTrue(RemoteTrackPath.isRemote(assetURL: URL(string: "flaccy-remote://srv/song")!))
        XCTAssertFalse(RemoteTrackPath.isRemote(assetURL: URL(fileURLWithPath: "/tmp/a.flac")))
    }
}
