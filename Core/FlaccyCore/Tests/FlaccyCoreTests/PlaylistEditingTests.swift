import XCTest
@testable import FlaccyCore

final class PlaylistEditingTests: XCTestCase {

    func testE1AnAdditionSkipsSongsThePlaylistHolds() {
        let addition = PlaylistEditing.addition(existing: ["a", "b"], adding: ["c", "a", "d", "b", "a"])
        XCTAssertEqual(addition.added, ["c", "d"])
        XCTAssertEqual(addition.alreadyIn, ["a", "b"])
    }

    func testE2AnAdditionNamingASongTwiceAddsItOnce() {
        let addition = PlaylistEditing.addition(existing: [], adding: ["x", "y", "x"])
        XCTAssertEqual(addition.added, ["x", "y"])
        XCTAssertEqual(addition.alreadyIn, [])
    }

    func testE3AMovedRowLandsWhereTheListSaysItEnds() {
        let order = ["a", "b", "c", "d", "e"]
        let down = PlaylistEditing.moved(order, moving: ["b"], to: PlaylistEditing.insertionIndex(movingRowFrom: 1, to: 3))
        XCTAssertEqual(down, ["a", "c", "d", "b", "e"])
        let up = PlaylistEditing.moved(order, moving: ["d"], to: PlaylistEditing.insertionIndex(movingRowFrom: 3, to: 0))
        XCTAssertEqual(up, ["d", "a", "b", "c", "e"])
        let last = PlaylistEditing.moved(order, moving: ["a"], to: PlaylistEditing.insertionIndex(movingRowFrom: 0, to: 4))
        XCTAssertEqual(last, ["b", "c", "d", "e", "a"])
    }

    func testE4SeveralRowsMoveTogetherInTheirOwnOrder() {
        let order = [1, 2, 3, 4, 5, 6]
        XCTAssertEqual(PlaylistEditing.moved(order, moving: [5, 2], to: 1), [1, 2, 5, 3, 4, 6])
        XCTAssertEqual(PlaylistEditing.moved(order, moving: [1, 3], to: 6), [2, 4, 5, 6, 1, 3])
        XCTAssertEqual(PlaylistEditing.moved(order, moving: [4], to: 4), order)
        XCTAssertEqual(PlaylistEditing.moved(order, moving: [9], to: 0), order)
        XCTAssertEqual(PlaylistEditing.moved(order, moving: [6], to: -3), [6, 1, 2, 3, 4, 5])
    }

    func testE5RemovedEntriesGoBackWhereTheyStood() {
        let original = ["a", "b", "c", "d", "e"]
        let removed = [(id: "d", index: 3), (id: "a", index: 0), (id: "b", index: 1)]
        let kept = original.filter { id in !removed.contains { $0.id == id } }
        XCTAssertEqual(PlaylistEditing.restored(kept: kept, removed: removed), original)
    }

    func testE6ARestoreIntoAShorterPlaylistPutsTheRestLast() {
        XCTAssertEqual(PlaylistEditing.restored(kept: ["x"], removed: [(id: "y", index: 5), (id: "z", index: 0)]), ["z", "x", "y"])
    }

    func testE7ACopyGetsTheFirstFreeName() {
        XCTAssertEqual(PlaylistEditing.copyName(of: "Night Drive", copyWord: "Copy", taken: ["Night Drive"]), "Night Drive Copy")
        XCTAssertEqual(
            PlaylistEditing.copyName(of: "Night Drive", copyWord: "Copy", taken: ["night drive copy", "Night Drive Copy 2"]),
            "Night Drive Copy 3"
        )
    }
}
