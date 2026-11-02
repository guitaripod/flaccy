import XCTest
@testable import FlaccyCore

final class LyricsPatienceTests: XCTestCase {

    func testOnlyABusyAnswerLetsTheNextQuestionBeAsked() {
        XCTAssertTrue(LyricsPatience.triesNextQuestion(after: .server(503)))
        XCTAssertFalse(LyricsPatience.triesNextQuestion(after: .server(500)))
        XCTAssertFalse(LyricsPatience.triesNextQuestion(after: .server(502)))
        XCTAssertFalse(LyricsPatience.triesNextQuestion(after: .timedOut))
        XCTAssertFalse(LyricsPatience.triesNextQuestion(after: .unreachable))
        XCTAssertFalse(LyricsPatience.triesNextQuestion(after: .busy))
        XCTAssertFalse(LyricsPatience.triesNextQuestion(after: .rejected(403)))
    }

    func testTheFirstFourFailuresWaitLongerEachTimeAndSayNothing() {
        let waits = (1...4).map { LyricsPatience.next(after: .server(503), failures: $0) }
        XCTAssertEqual(waits, [.quietly(after: 3), .quietly(after: 8), .quietly(after: 20), .quietly(after: 45)])
    }

    func testTheFifthFailureIsShownOnceAndTheLaterOnesStayQuiet() {
        XCTAssertEqual(LyricsPatience.next(after: .timedOut, failures: 5), .show(after: 60))
        XCTAssertEqual(LyricsPatience.next(after: .timedOut, failures: 6), .quietly(after: 60))
        XCTAssertEqual(LyricsPatience.next(after: .timedOut, failures: 40), .quietly(after: 60))
    }

    func testACooldownTheServerAskedForIsNeverUndercut() {
        XCTAssertEqual(LyricsPatience.next(after: .busy, failures: 1, cooldownLeft: 120), .quietly(after: 120))
        XCTAssertEqual(LyricsPatience.next(after: .busy, failures: 1, cooldownLeft: 1), .quietly(after: 3))
        XCTAssertEqual(LyricsPatience.next(after: .busy, failures: 5, cooldownLeft: 300), .show(after: 300))
    }

    func testARefusalIsShownAtOnceAndNotRetried() {
        XCTAssertEqual(LyricsPatience.next(after: .rejected(403), failures: 1), .giveUp)
    }

    func testAConnectionThatCannotOpenIsRetriedLikeAServerError() {
        XCTAssertEqual(LyricsPatience.next(after: .unreachable, failures: 2), .quietly(after: 8))
    }
}
