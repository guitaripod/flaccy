import FlaccyCore
import GRDB
import XCTest
@testable import flaccy

nonisolated final class DatabaseManagerRemoteTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("flaccy-remote-db-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testTheFolderScanNeverSeesARemoteRowAndNeverDeletesOne() throws {
        let manager = try makeManager()
        try manager.insertTracks([localRow("Music/a.flac")])
        try manager.applyRemoteCatalog(change(inserts: ["s1", "s2"]))
        let playlist = try manager.createPlaylist(name: "Mix")
        let playlistID = try XCTUnwrap(playlist.id)
        let remotePath = RemoteTrackPath(serverID: "srv", songID: "s1").path
        try manager.addTracksToPlaylist(playlistId: playlistID, trackFileURLs: ["Music/a.flac", remotePath])

        XCTAssertEqual(try manager.fetchAllTrackRelativePaths(), ["Music/a.flac"])

        try manager.deleteTracksNotIn(relativePaths: [])

        XCTAssertEqual(try manager.fetchRemoteTrackPaths(serverID: "srv").count, 2)
        XCTAssertNil(try manager.fetchTrack(byRelativePath: "Music/a.flac"))
        XCTAssertEqual(try manager.fetchPlaylistTracks(playlistId: playlistID).map(\.trackFileURL), [remotePath])
    }

    func testACatalogChangeInsertsUpdatesVersionsAndRemoves() throws {
        let manager = try makeManager()
        try manager.applyRemoteCatalog(change(inserts: ["a", "b", "c"]))
        let now = Date(timeIntervalSince1970: 2_000_000)
        var renamed = facts(title: "Renamed")
        renamed.trackNumber = 7
        var reencoded = facts(title: "Song")
        reencoded.size = 9_999
        reencoded.fingerprint = "flac:new"

        try manager.applyRemoteCatalog(RemoteCatalogChange(
            serverID: "srv", inserts: [(songID: "d", facts: facts(title: "Fresh"))],
            updates: [(songID: "a", facts: renamed)], newVersions: [(songID: "b", facts: reencoded)],
            removedSongIDs: ["c"], now: now
        ))

        let paths = Set(try manager.fetchRemoteTrackPaths(serverID: "srv"))
        XCTAssertEqual(paths, Set(["a", "b", "d"].map { RemoteTrackPath(serverID: "srv", songID: $0).path }))
        let updated = try XCTUnwrap(manager.fetchTrack(byRelativePath: RemoteTrackPath(serverID: "srv", songID: "a").path))
        XCTAssertEqual(updated.title, "Renamed")
        XCTAssertEqual(updated.trackNumber, 7)
        XCTAssertEqual(updated.revision, 1)
        let versioned = try XCTUnwrap(manager.fetchTrack(byRelativePath: RemoteTrackPath(serverID: "srv", songID: "b").path))
        XCTAssertEqual(versioned.revision, 2)
        XCTAssertEqual(versioned.revisedAt, now)
        XCTAssertEqual(versioned.remoteSize, 9_999)
        XCTAssertEqual(versioned.audioFingerprint, "flac:new")
        XCTAssertTrue(versioned.aiAnalyzed, "the AI cleanup leaves a server's tags alone")
    }

    func testTheDiffAgainstTheStoredRowsFindsNothingWhenNothingChanged() throws {
        let manager = try makeManager()
        try manager.applyRemoteCatalog(change(inserts: ["a", "b"]))

        let local = try manager.fetchRemoteCatalogItems(serverID: "srv")
        let server = ["a", "b"].map { id in
            RemoteCatalogDiff.Item(
                id: id, size: 1_000, duration: 20, title: "Song", artist: "Artist", album: "Album", track: 1, fingerprint: nil
            )
        }

        let diff = RemoteCatalogDiff.diff(server: server, local: local)

        XCTAssertTrue(diff.inserted.isEmpty && diff.updated.isEmpty && diff.newVersions.isEmpty && diff.removed.isEmpty)
    }

    func testStarsPlayCountsAndLastPlayFollowTheServer() throws {
        let manager = try makeManager()
        try manager.applyRemoteCatalog(change(inserts: ["a", "b"]))
        let path = RemoteTrackPath(serverID: "srv", songID: "a").path
        let other = RemoteTrackPath(serverID: "srv", songID: "b").path
        try manager.setPlayCount(relativePath: path, count: 5)
        try manager.setLoved(fileURL: other, loved: false, pendingOp: "love")
        let played = Date(timeIntervalSince1970: 1_800_000_000)

        try manager.applyRemoteCatalog(RemoteCatalogChange(
            serverID: "srv", inserts: [], updates: [], newVersions: [], removedSongIDs: [],
            playStates: [
                RemoteSongPlayState(songID: "a", starred: true, playCount: 3, played: played),
                RemoteSongPlayState(songID: "b", starred: true, playCount: 2, played: nil),
            ],
            now: Date()
        ))

        let first = try XCTUnwrap(manager.fetchTrack(byRelativePath: path))
        XCTAssertTrue(first.loved)
        XCTAssertEqual(first.playCount, 5, "the larger count wins")
        XCTAssertEqual(first.lastPlayed, played)
        let second = try XCTUnwrap(manager.fetchTrack(byRelativePath: other))
        XCTAssertFalse(second.loved, "a love waiting to be sent is not overwritten")
        XCTAssertEqual(second.playCount, 2)
        XCTAssertNil(second.lastPlayed)

        try manager.applyRemoteCatalog(RemoteCatalogChange(
            serverID: "srv", inserts: [], updates: [], newVersions: [], removedSongIDs: [],
            playStates: [RemoteSongPlayState(songID: "a", starred: false, playCount: nil, played: played.addingTimeInterval(-60))],
            now: Date()
        ))
        let unstarred = try XCTUnwrap(manager.fetchTrack(byRelativePath: path))
        XCTAssertFalse(unstarred.loved)
        XCTAssertEqual(unstarred.lastPlayed, played, "the later play stays")
    }

    func testRemovingAServerRemovesItsRowsAndPlaylistPlacesButNotLocalOnes() throws {
        let manager = try makeManager()
        try manager.insertTracks([localRow("Music/a.flac")])
        try manager.saveRemoteServer(server())
        try manager.applyRemoteCatalog(change(inserts: ["s1"]))
        let playlist = try manager.createPlaylist(name: "Mix")
        let playlistID = try XCTUnwrap(playlist.id)
        try manager.addTracksToPlaylist(
            playlistId: playlistID, trackFileURLs: ["Music/a.flac", RemoteTrackPath(serverID: "srv", songID: "s1").path]
        )

        let removed = try manager.deleteRemoteServer(id: "srv")

        XCTAssertEqual(removed, [RemoteTrackPath(serverID: "srv", songID: "s1").path])
        XCTAssertNil(try manager.fetchRemoteServer(id: "srv"))
        XCTAssertEqual(try manager.fetchPlaylistTracks(playlistId: playlistID).map(\.trackFileURL), ["Music/a.flac"])
        XCTAssertNotNil(try manager.fetchTrack(byRelativePath: "Music/a.flac"))
    }

    func testAServerRoundTripsAndBumpingARevisionRecordsTheNewSize() throws {
        let manager = try makeManager()
        var record = server()
        record.extensionNames = ["songLyrics", "transcoding"]
        try manager.saveRemoteServer(record)
        try manager.applyRemoteCatalog(change(inserts: ["s1"]))
        let path = RemoteTrackPath(serverID: "srv", songID: "s1").path

        XCTAssertEqual(try manager.fetchRemoteServer(id: "srv")?.extensionNames, ["songLyrics", "transcoding"])
        XCTAssertTrue(try manager.bumpRemoteRevision(path: path, size: 4_321, now: Date(timeIntervalSince1970: 5)))
        let row = try XCTUnwrap(manager.fetchTrack(byRelativePath: path))
        XCTAssertEqual(row.revision, 2)
        XCTAssertEqual(row.remoteSize, 4_321)
        XCTAssertFalse(try manager.bumpRemoteRevision(path: "Music/a.flac", size: 1, now: Date()))
    }

    func testTheTrackModelOfARemoteRowCarriesTheAssetURL() throws {
        let manager = try makeManager()
        try manager.applyRemoteCatalog(change(inserts: ["s1"]))
        let record = try XCTUnwrap(manager.fetchTrack(byRelativePath: RemoteTrackPath(serverID: "srv", songID: "s1").path))

        let track = Track.from(record: record, artwork: nil)

        XCTAssertEqual(track.fileURL, RemoteTrackPath(serverID: "srv", songID: "s1").assetURL)
        XCTAssertEqual(track.remoteSong?.songID, "s1")
        XCTAssertEqual(LibraryPaths.relativePath(of: track.fileURL), record.fileURL)
    }

    func testPinningAnAlbumFlagsItsSongs() throws {
        let manager = try makeManager()
        try manager.applyRemoteCatalog(change(inserts: ["a", "b"]))
        let paths = try manager.fetchRemoteAlbumPaths(containing: RemoteTrackPath(serverID: "srv", songID: "a").path)

        try manager.setRemotePinned(paths: paths, pinned: true)

        XCTAssertEqual(Set(paths), Set(try manager.fetchPinnedRemotePaths(serverID: "srv")))
        XCTAssertEqual(try manager.fetchRemoteSongSource(path: paths[0])?.pinned, true)
    }

    private func makeManager() throws -> DatabaseManager {
        try DatabaseManager(path: directory.appendingPathComponent("library.sqlite").path)
    }

    private func server() -> RemoteServerRecord {
        RemoteServerRecord(
            id: "srv", name: "NAS", baseURL: "http://nas:4533", username: "flaccy", authKind: .password, addedAt: Date()
        )
    }

    private func facts(title: String) -> RemoteSongFacts {
        RemoteSongFacts(
            title: title, artist: "Artist", albumTitle: "Album", albumArtist: nil, trackNumber: 1, duration: 20,
            suffix: "flac", size: 1_000, coverArt: nil, albumId: "al1", codec: "FLAC", bitDepth: 16, sampleRate: 44_100,
            channels: 2, fingerprint: nil
        )
    }

    private func change(inserts: [String]) -> RemoteCatalogChange {
        RemoteCatalogChange(
            serverID: "srv", inserts: inserts.map { (songID: $0, facts: facts(title: "Song")) }, updates: [],
            newVersions: [], removedSongIDs: [], now: Date()
        )
    }

    private func localRow(_ path: String) -> TrackRecord {
        TrackRecord(
            fileURL: path, title: "Local", artist: "Artist", albumTitle: "Local Album", trackNumber: 1, duration: 100,
            dateAdded: Date(), playCount: 0, aiAnalyzed: false
        )
    }
}
