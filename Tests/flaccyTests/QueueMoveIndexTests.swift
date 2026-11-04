import XCTest
@testable import FlaccyEngine

/// The playing song keeps its place when another moves around it, found by
/// position because the same song can sit in the queue twice.
nonisolated final class QueueMoveIndexTests: XCTestCase {

    func testMovingAWaitingSongNeverMovesThePlayingCopyOfADuplicate() {
        XCTAssertEqual(PlaybackEngine.index(of: 2, afterMovingFrom: 4, to: 3), 2)
        XCTAssertEqual(PlaybackEngine.index(of: 2, afterMovingFrom: 3, to: 4), 2)
    }

    func testSongsCrossingThePlayingOneShiftIt() {
        XCTAssertEqual(PlaybackEngine.index(of: 2, afterMovingFrom: 0, to: 3), 1)
        XCTAssertEqual(PlaybackEngine.index(of: 2, afterMovingFrom: 4, to: 1), 3)
        XCTAssertEqual(PlaybackEngine.index(of: 2, afterMovingFrom: 2, to: 4), 4)
    }
}
