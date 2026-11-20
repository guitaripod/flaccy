import XCTest
@testable import FlaccyCore

/// The pairing of a device's songs with a server's copies. The same cases run in Rust in
/// `linux/shared/src/remote/server_move.rs`.
final class ServerMovePlanTests: XCTestCase {

    private func song(
        _ path: String, key: String = "k", album: String = "a", track: Int = 1, ms: Int64 = 200_000, fp: String? = nil,
        rank: Int = 0
    ) -> ServerMovePlan.Song {
        ServerMovePlan.Song(path: path, songKey: key, albumKey: album, track: track, durationMs: ms, fingerprint: fp, rank: rank)
    }

    private func duplicates(_ result: ServerMovePlan.Result) -> [String: String] {
        Dictionary(uniqueKeysWithValues: result.duplicates.map { ($0.local, $0.server) })
    }

    private func pairs(_ result: ServerMovePlan.Result) -> [String: String] {
        Dictionary(uniqueKeysWithValues: result.pairs.map { ($0.local, $0.server) })
    }

    func testSameKeysAlbumAndLengthPair() {
        let result = ServerMovePlan.plan(local: [song("L/a.m4a", ms: 200_400)], server: [song("remote://s/1", ms: 200_000)])
        XCTAssertEqual(pairs(result), ["L/a.m4a": "remote://s/1"])
        XCTAssertEqual(result.unmatched, [])
    }

    func testLengthBeyondToleranceStaysOnTheDevice() {
        let result = ServerMovePlan.plan(local: [song("L/a.m4a", ms: 202_001)], server: [song("remote://s/1", ms: 200_000)])
        XCTAssertEqual(pairs(result), [:])
        XCTAssertEqual(result.unmatched, ["L/a.m4a"])
    }

    func testLengthAtToleranceStillPairs() {
        let result = ServerMovePlan.plan(local: [song("L/a.m4a", ms: 202_000)], server: [song("remote://s/1", ms: 200_000)])
        XCTAssertEqual(pairs(result), ["L/a.m4a": "remote://s/1"])
    }

    func testAnotherAlbumWithAnotherTrackNumberStaysOnTheDevice() {
        let result = ServerMovePlan.plan(
            local: [song("L/a.m4a", album: "hits", track: 7)], server: [song("remote://s/1", album: "a", track: 1)]
        )
        XCTAssertEqual(result.unmatched, ["L/a.m4a"])
    }

    func testAnotherAlbumWithoutATrackNumberStaysOnTheDevice() {
        let result = ServerMovePlan.plan(
            local: [song("L/a.m4a", album: "hits", track: 0)], server: [song("remote://s/1", album: "a", track: 0)]
        )
        XCTAssertEqual(result.unmatched, ["L/a.m4a"])
    }

    func testSameTrackNumberPairsAcrossADiscSuffix() {
        let result = ServerMovePlan.plan(
            local: [song("L/a.m4a", album: "ost disc 2", track: 24, ms: 75_700)],
            server: [song("remote://s/1", album: "ost", track: 24, ms: 75_000)]
        )
        XCTAssertEqual(pairs(result), ["L/a.m4a": "remote://s/1"])
    }

    func testSameAlbumBeatsAnotherAlbumWithTheSameTrackNumber() {
        let result = ServerMovePlan.plan(
            local: [song("L/a.m4a", album: "a", track: 3)],
            server: [song("remote://s/1", album: "best of", track: 3), song("remote://s/2", album: "a", track: 9)]
        )
        XCTAssertEqual(pairs(result), ["L/a.m4a": "remote://s/2"])
    }

    func testAnotherSongKeyStaysOnTheDevice() {
        let result = ServerMovePlan.plan(local: [song("L/a.m4a", key: "x")], server: [song("remote://s/1", key: "y")])
        XCTAssertEqual(result.unmatched, ["L/a.m4a"])
    }

    func testEmptySongKeyNeverPairsByMetadata() {
        let result = ServerMovePlan.plan(local: [song("L/a.m4a", key: "")], server: [song("remote://s/1", key: "")])
        XCTAssertEqual(result.unmatched, ["L/a.m4a"])
    }

    func testSameAudioPairsWhateverTheAlbumAndLengthSay() {
        let result = ServerMovePlan.plan(
            local: [song("L/a.flac", album: "other", track: 4, ms: 10_000, fp: "flac:abc")],
            server: [song("remote://s/1", album: "a", track: 1, ms: 200_000, fp: "flac:abc")]
        )
        XCTAssertEqual(pairs(result), ["L/a.flac": "remote://s/1"])
    }

    func testSameAudioUnderAnotherSongKeyStaysOnTheDevice() {
        let result = ServerMovePlan.plan(
            local: [song("L/a.flac", key: "x", fp: "flac:abc")],
            server: [song("remote://s/1", key: "y", fp: "flac:abc")]
        )
        XCTAssertEqual(result.unmatched, ["L/a.flac"])
    }

    func testSameAudioWinsOverMetadata() {
        let result = ServerMovePlan.plan(
            local: [song("L/a.flac", fp: "flac:abc")],
            server: [song("remote://s/1"), song("remote://s/2", fp: "flac:abc")]
        )
        XCTAssertEqual(pairs(result), ["L/a.flac": "remote://s/2"])
    }

    func testASecondCopyOnTheDeviceIsADuplicateOfThePair() {
        let result = ServerMovePlan.plan(
            local: [song("L/a.m4a"), song("L/b.m4a")],
            server: [song("remote://s/1")]
        )
        XCTAssertEqual(pairs(result), ["L/a.m4a": "remote://s/1"])
        XCTAssertEqual(duplicates(result), ["L/b.m4a": "remote://s/1"])
        XCTAssertEqual(result.unmatched, [])
    }

    func testTheCopyThePersonUsesBecomesThePair() {
        let result = ServerMovePlan.plan(
            local: [song("L/a.m4a", rank: 0), song("L/b.m4a", rank: 3)],
            server: [song("remote://s/1")]
        )
        XCTAssertEqual(pairs(result), ["L/b.m4a": "remote://s/1"])
        XCTAssertEqual(duplicates(result), ["L/a.m4a": "remote://s/1"])
    }

    func testTheCopyOnTheWatchBeatsACloserLength() {
        let result = ServerMovePlan.plan(
            local: [song("L/a.m4a", ms: 200_000, rank: 0), song("L/b.m4a", ms: 201_000, rank: 9)],
            server: [song("remote://s/1", ms: 200_000)]
        )
        XCTAssertEqual(pairs(result), ["L/b.m4a": "remote://s/1"])
        XCTAssertEqual(duplicates(result), ["L/a.m4a": "remote://s/1"])
    }

    func testCloserLengthDecidesBetweenCopiesUsedAlike() {
        let result = ServerMovePlan.plan(
            local: [song("L/a.m4a", ms: 201_000), song("L/b.m4a", ms: 200_000)],
            server: [song("remote://s/1", ms: 200_000)]
        )
        XCTAssertEqual(pairs(result), ["L/b.m4a": "remote://s/1"])
    }

    func testAnotherAlbumBeyondASecondStaysOnTheDevice() {
        let result = ServerMovePlan.plan(
            local: [song("L/live.m4a", album: "x live", track: 3, ms: 119_600)],
            server: [song("remote://s/1", album: "x", track: 3, ms: 120_800)]
        )
        XCTAssertEqual(result.unmatched, ["L/live.m4a"])
    }

    func testTrackNumberSortsTwinsOnOneAlbum() {
        let result = ServerMovePlan.plan(
            local: [song("L/2-intro.m4a", track: 1, ms: 61_000), song("L/1-intro.m4a", track: 9, ms: 60_000)],
            server: [song("remote://s/a", track: 9, ms: 61_000), song("remote://s/b", track: 1, ms: 60_000)]
        )
        XCTAssertEqual(pairs(result), ["L/2-intro.m4a": "remote://s/b", "L/1-intro.m4a": "remote://s/a"])
    }

    func testClosestLengthWinsWhenTrackNumbersDoNotHelp() {
        let result = ServerMovePlan.plan(
            local: [song("L/a.m4a", track: 0, ms: 100_000), song("L/b.m4a", track: 0, ms: 101_500)],
            server: [song("remote://s/1", track: 0, ms: 101_000), song("remote://s/2", track: 0, ms: 100_000)]
        )
        XCTAssertEqual(pairs(result), ["L/a.m4a": "remote://s/2", "L/b.m4a": "remote://s/1"])
    }

    func testOrderOfArrivalDoesNotChangeThePairs() {
        let local = [song("L/a.m4a", ms: 200_000), song("L/b.m4a", ms: 200_500), song("L/c.m4a", ms: 199_000)]
        let server = [song("remote://s/1", ms: 200_000), song("remote://s/2", ms: 201_000)]
        let forward = ServerMovePlan.plan(local: local, server: server)
        let backward = ServerMovePlan.plan(local: local.reversed(), server: server.reversed())
        XCTAssertEqual(forward, backward)
        XCTAssertEqual(pairs(forward), ["L/a.m4a": "remote://s/1", "L/b.m4a": "remote://s/2"])
        XCTAssertEqual(duplicates(forward), ["L/c.m4a": "remote://s/1"])
        XCTAssertEqual(forward.unmatched, [])
    }

    func testNothingOnTheServerLeavesEverySongSorted() {
        let result = ServerMovePlan.plan(local: [song("L/b.m4a"), song("L/a.m4a")], server: [])
        XCTAssertEqual(result.pairs, [])
        XCTAssertEqual(result.duplicates, [])
        XCTAssertEqual(result.unmatched, ["L/a.m4a", "L/b.m4a"])
    }
}
