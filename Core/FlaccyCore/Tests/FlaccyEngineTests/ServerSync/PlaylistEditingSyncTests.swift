import FlaccyCore
import GRDB
import XCTest

@testable import FlaccyEngine

/// The playlist edits the remastered pages make, each one commit: a drag, a
/// removal and its Undo, an addition that skips what the playlist holds, a
/// copy. Each must reach a second device through the server in the same order.
final class PlaylistEditingSyncTests: XCTestCase {

    private func pair(_ titles: [String]) async throws -> (SyncDevice, SyncDevice, FakeFlaccyServer, [TrackRecord]) {
        let server = FakeFlaccyServer()
        let first = try makeDevice(server)
        let second = try makeDevice(server)
        server.newCode("SECOND")
        let songs = try titles.map { try first.addTrack($0) }
        for title in titles { try second.addTrack(title) }
        _ = try await first.connect()
        _ = try await second.connect(code: "SECOND")
        return (first, second, server, songs)
    }

    private func entryIDs(_ device: SyncDevice, _ playlist: Int64) throws -> [Int64] {
        try device.database.fetchPlaylistTracks(playlistId: playlist).compactMap(\.id)
    }

    func testOneDraggedRowIsOneCommitAndOneMove() async throws {
        let (first, second, server, songs) = try await pair(["A", "B", "C", "D", "E"])
        let playlist = try XCTUnwrap(first.database.createPlaylist(name: "Mix", trackFileURLs: songs.map(\.fileURL)).id)
        assertUpToDate(await first.settle())
        assertUpToDate(await second.settle())
        let ids = try entryIDs(first, playlist)
        let before = try first.pendingNames().count
        let order = PlaylistEditing.moved(ids, moving: [ids[0]], to: PlaylistEditing.insertionIndex(movingRowFrom: 0, to: 3))
        try first.database.reorderPlaylist(playlistId: playlist, orderedEntryIDs: order)
        XCTAssertEqual(Array(try first.pendingNames().dropFirst(before)), ["entry.move"])
        XCTAssertEqual(try first.read { try Int.fetchAll($0, sql: "SELECT position FROM playlistTracks WHERE playlistId = ? ORDER BY position", arguments: [playlist]) }, [0, 1, 2, 3, 4])
        assertUpToDate(await first.settle())
        assertUpToDate(await second.settle())
        XCTAssertEqual(try second.playlistTitles("Mix"), ["B", "C", "D", "A", "E"])
        XCTAssertEqual(server.titles(in: "Mix"), ["B", "C", "D", "A", "E"])

        let unchanged = try first.pendingNames().count
        try first.database.reorderPlaylist(playlistId: playlist, orderedEntryIDs: try entryIDs(first, playlist))
        XCTAssertEqual(try first.pendingNames().count, unchanged)
    }

    func testRemovedSongsComeBackWhereTheyStoodOnEveryDevice() async throws {
        let (first, second, server, songs) = try await pair(["A", "B", "C", "D", "E"])
        let playlist = try XCTUnwrap(first.database.createPlaylist(name: "Mix", trackFileURLs: songs.map(\.fileURL)).id)
        assertUpToDate(await first.settle())
        assertUpToDate(await second.settle())
        let ids = try entryIDs(first, playlist)
        let removed = try first.database.removePlaylistEntries(ids: [ids[3], ids[0]], fromPlaylist: playlist)
        XCTAssertEqual(removed.map(\.index), [0, 3])
        assertUpToDate(await first.settle())
        assertUpToDate(await second.settle())
        XCTAssertEqual(try second.playlistTitles("Mix"), ["B", "C", "E"])

        try first.database.restorePlaylistEntries(removed, toPlaylist: playlist)
        XCTAssertEqual(try first.playlistTitles("Mix"), ["A", "B", "C", "D", "E"])
        assertUpToDate(await first.settle())
        assertUpToDate(await second.settle())
        XCTAssertEqual(try second.playlistTitles("Mix"), ["A", "B", "C", "D", "E"])
        XCTAssertEqual(server.titles(in: "Mix"), ["A", "B", "C", "D", "E"])
    }

    func testAnAdditionSkipsWhatThePlaylistHolds() async throws {
        let (first, second, _, songs) = try await pair(["A", "B", "C"])
        let playlist = try XCTUnwrap(first.database.createPlaylist(name: "Mix", trackFileURLs: [songs[0].fileURL, songs[0].fileURL]).id)
        XCTAssertEqual(try first.playlistTitles("Mix"), ["A"])
        let addition = try first.database.addMissingTracksToPlaylist(
            playlistId: playlist, trackFileURLs: [songs[1].fileURL, songs[0].fileURL, songs[2].fileURL, songs[1].fileURL]
        )
        XCTAssertEqual(addition.added, [songs[1].fileURL, songs[2].fileURL])
        XCTAssertEqual(addition.alreadyIn, [songs[0].fileURL])
        XCTAssertEqual(try first.database.playlistIDs(containingTrack: songs[2].fileURL), [playlist])
        assertUpToDate(await first.settle())
        assertUpToDate(await second.settle())
        XCTAssertEqual(try second.playlistTitles("Mix"), ["A", "B", "C"])
    }

    func testACopyCarriesTheSongsTheOrderAndTheCover() async throws {
        let (first, second, _, songs) = try await pair(["A", "B", "C"])
        let playlist = try XCTUnwrap(first.database.createPlaylist(name: "Mix", trackFileURLs: songs.reversed().map(\.fileURL)).id)
        try first.database.savePlaylistCover(Data([1, 2, 3]), id: playlist)
        let copy = try XCTUnwrap(first.database.duplicatePlaylist(id: playlist, name: "Mix Copy").id)
        XCTAssertNotEqual(copy, playlist)
        XCTAssertEqual(try first.playlistTitles("Mix Copy"), ["C", "B", "A"])
        XCTAssertEqual(try first.database.playlistCover(id: copy), Data([1, 2, 3]))
        let summaries = try first.database.fetchPlaylistSummaries()
        XCTAssertEqual(summaries[copy], PlaylistSummary(songCount: 3, seconds: 600))
        assertUpToDate(await first.settle())
        assertUpToDate(await second.settle())
        XCTAssertEqual(try second.playlistTitles("Mix Copy"), ["C", "B", "A"])
    }

    func testTheMovesTurnAnyOrderIntoAnother() {
        let current = ["a", "b", "c", "d", "e", "f"]
        for wanted in [["f", "e", "d", "c", "b", "a"], ["b", "a", "c", "d", "f", "e"], current, ["c", "a", "b", "d", "e", "f"]] {
            var order = current
            for (entry, place) in ServerSyncRecorder.moves(from: current, to: wanted) {
                order.removeAll { $0 == entry }
                if place["kind"]?.string == "first" {
                    order.insert(entry, at: 0)
                } else if let after = place["id"]?.string, let index = order.firstIndex(of: after) {
                    order.insert(entry, at: index + 1)
                }
            }
            XCTAssertEqual(order, wanted)
        }
        XCTAssertEqual(ServerSyncRecorder.moves(from: current, to: current).count, 0)
        XCTAssertEqual(ServerSyncRecorder.moves(from: current, to: ["b", "c", "d", "e", "f", "a"]).count, 1)
    }
}

final class PlaylistEntriesTests: XCTestCase {

    func testEntriesCarryTheirSongOrNilWhenTheLibraryLostIt() async throws {
        let device = try makeDevice(FakeFlaccyServer())
        let songs = try ["A", "B"].map { try device.addTrack($0) }
        let playlist = try XCTUnwrap(device.database.createPlaylist(
            name: "Mix", trackFileURLs: [songs[1].fileURL, "Gone/Missing.flac", songs[0].fileURL]
        ).id)
        let entries = try device.database.fetchPlaylistEntries(playlistId: playlist)
        XCTAssertEqual(entries.map(\.record.trackFileURL), [songs[1].fileURL, "Gone/Missing.flac", songs[0].fileURL])
        XCTAssertEqual(entries.map { $0.track?.title }, ["B", nil, "A"])
        let summary = try XCTUnwrap(device.database.fetchPlaylistSummaries()[playlist])
        XCTAssertEqual(summary, PlaylistSummary(songCount: 3, seconds: 400))
    }

    @MainActor func testTheObservationFollowsEveryEdit() async throws {
        let device = try makeDevice(FakeFlaccyServer())
        let songs = try ["A", "B", "C"].map { try device.addTrack($0) }
        let playlist = try XCTUnwrap(device.database.createPlaylist(name: "Mix", trackFileURLs: songs.map(\.fileURL)).id)
        let seen = expectation(description: "the removal arrives")
        var titles: [[String]] = []
        let token = device.database.observePlaylistEntries(playlistId: playlist) { entries in
            titles.append(entries.compactMap { $0.track?.title })
            if titles.last == ["A", "C"] { seen.fulfill() }
        }
        let rows = try device.database.fetchPlaylistTracks(playlistId: playlist)
        try device.database.removePlaylistEntries(ids: [try XCTUnwrap(rows[1].id)], fromPlaylist: playlist)
        await fulfillment(of: [seen], timeout: 5)
        token.cancel()
        XCTAssertEqual(titles.first, ["A", "B", "C"])
    }
}
