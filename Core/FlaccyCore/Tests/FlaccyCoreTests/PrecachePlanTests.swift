import XCTest
@testable import FlaccyCore

final class PrecachePlanTests: XCTestCase {

    private func candidate(_ key: String) -> PrecacheCandidate {
        PrecacheCandidate(key: key, daysSinceAdded: 400)
    }

    private func queued(_ key: String, _ distance: Int) -> PrecacheCandidate {
        var queued = candidate(key)
        queued.queueDistance = distance
        return queued
    }

    func testLyricsCoverTheQueueAndHabitFirstAndTheLibraryOnlyWhenAsked() {
        var known = candidate("known")
        known.playsTotal = 9
        let candidates = [candidate("stranger"), queued("next", 1), known]
        XCTAssertEqual(PrecachePlan.lyricsOrder(candidates, wholeLibrary: false), ["next", "known"])
        XCTAssertEqual(PrecachePlan.lyricsOrder(candidates, wholeLibrary: true), ["next", "known", "stranger"])
    }

    func testANewArrivalIsAskedAboutBeforeAnOldStranger() {
        var fresh = candidate("fresh")
        fresh.daysSinceAdded = 2
        XCTAssertEqual(PrecachePlan.lyricsOrder([candidate("old"), fresh], wholeLibrary: true), ["fresh", "old"])
    }

    func testTiesBreakByKeySoPlanningTwiceAgrees() {
        let candidates = [candidate("b"), candidate("c"), candidate("a")]
        XCTAssertEqual(PrecachePlan.lyricsOrder(candidates, wholeLibrary: true), ["a", "b", "c"])
    }

    func testTheRetryLadderDoublesPerFailureKindAndJitterOnlyLengthens() {
        XCTAssertEqual(PrecachePlan.retryDelaySeconds(.transient, attempts: 1, jitter: 0), 30)
        XCTAssertEqual(PrecachePlan.retryDelaySeconds(.transient, attempts: 3, jitter: 0), 120)
        XCTAssertEqual(PrecachePlan.retryDelaySeconds(.transient, attempts: 30, jitter: 0), 3_600)
        XCTAssertEqual(PrecachePlan.retryDelaySeconds(.busy, attempts: 1, jitter: 0), 30)
        XCTAssertEqual(PrecachePlan.retryDelaySeconds(.busy, attempts: 3, jitter: 0), 120)
        XCTAssertEqual(PrecachePlan.retryDelaySeconds(.throttled, attempts: 1, jitter: 0), 300)
        XCTAssertEqual(PrecachePlan.retryDelaySeconds(.blocked, attempts: 1, jitter: 0), 1_800)
        XCTAssertEqual(PrecachePlan.retryDelaySeconds(.notFound, attempts: 1, jitter: 0), 604_800)
        XCTAssertEqual(PrecachePlan.retryDelaySeconds(.transient, attempts: 1, jitter: 1), 39)
        XCTAssertEqual(PrecachePlan.retryDelaySeconds(.transient, attempts: 1, jitter: 7), 39)
    }

    func testAFailedSongWaitsLongerEachTimeAndIsForgivenByASuccess() {
        let start = Date(timeIntervalSince1970: 1_000)
        var ledger = PrecacheRetryLedger()
        ledger.failed("a", .transient, now: start, jitter: 0)
        XCTAssertTrue(ledger.isWaiting("a", now: start.addingTimeInterval(29)))
        XCTAssertFalse(ledger.isWaiting("a", now: start.addingTimeInterval(30)))
        ledger.failed("a", .transient, now: start.addingTimeInterval(30), jitter: 0)
        XCTAssertEqual(ledger.nextDue(now: start.addingTimeInterval(30)), start.addingTimeInterval(90))
        ledger.succeeded("a")
        XCTAssertFalse(ledger.isWaiting("a", now: start.addingTimeInterval(31)))
        XCTAssertNil(ledger.nextDue(now: start.addingTimeInterval(31)))
    }

    func testTheLedgerCountsOnlyTheSongsStillWaitingAndNamesTheFirstDue() {
        let start = Date(timeIntervalSince1970: 0)
        var ledger = PrecacheRetryLedger()
        ledger.failed("quick", .transient, now: start, jitter: 0)
        ledger.failed("slow", .throttled, now: start, jitter: 0)
        XCTAssertEqual(ledger.waiting(now: start), 2)
        XCTAssertEqual(ledger.nextDue(now: start), start.addingTimeInterval(30))
        XCTAssertEqual(ledger.waiting(now: start.addingTimeInterval(60)), 1)
        XCTAssertEqual(ledger.nextDue(now: start.addingTimeInterval(60)), start.addingTimeInterval(300))
        XCTAssertFalse(ledger.isWaiting("never-failed", now: start))
    }
}
