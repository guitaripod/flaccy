import XCTest
@testable import FlaccyCore

final class WatchSyncLedgerAdoptionTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 2_000_000)

    private func ledger(_ stems: [String]) -> WatchSyncLedger {
        var ledger = WatchSyncLedger()
        ledger.request(stems.map { (stem: $0, bytes: 5_000_000) }, now: t0)
        return ledger
    }

    func testAdoptingAQueuedStemMarksItSending() {
        var ledger = ledger(["a"])
        XCTAssertTrue(ledger.adopt(stem: "a", bytes: 7_000_000, fraction: 0.4))
        XCTAssertEqual(ledger.phase(of: "a"), .sending(fraction: 0.4))
        XCTAssertEqual(ledger.inFlightCount, 1)
        XCTAssertEqual(ledger.nextToStart(now: t0), [])
    }

    func testAdoptingKeepsAStemAlreadyInFlight() {
        var ledger = ledger(["a"])
        _ = ledger.nextToStart(now: t0)
        ledger.markHandedOff(stem: "a", now: t0)
        XCTAssertTrue(ledger.adopt(stem: "a", bytes: 1, fraction: 0.1))
        XCTAssertEqual(ledger.phase(of: "a"), .awaitingAck(since: t0))
    }

    func testAdoptionRefusesWhatIsNotWanted() {
        var ledger = ledger(["a"])
        XCTAssertFalse(ledger.adopt(stem: "unknown", bytes: 1, fraction: 0))
        ledger.ingest(confirmed: ["a"], watchFreeBytes: 1, watchIsFull: false, now: t0)
        XCTAssertFalse(ledger.adopt(stem: "a", bytes: 1, fraction: 0))
        ledger.ingest(confirmed: ["a", "stranger"], watchFreeBytes: 1, watchIsFull: false, now: t0)
        XCTAssertFalse(ledger.adopt(stem: "stranger", bytes: 1, fraction: 0))
    }

    func testAdoptedTransferCountsAgainstTheAdmissionBudget() {
        var ledger = ledger(["a", "b", "c", "d", "e"])
        XCTAssertTrue(ledger.adopt(stem: "a", bytes: 5_000_000, fraction: 0))
        XCTAssertEqual(ledger.nextToStart(now: t0), ["b", "c", "d"])
    }

    func testLostAcksReturnToTheQueueWithoutAHeartbeat() {
        var ledger = ledger(["a"])
        _ = ledger.nextToStart(now: t0)
        ledger.markHandedOff(stem: "a", now: t0)
        ledger.expireLostAcks(now: t0.addingTimeInterval(119))
        XCTAssertEqual(ledger.phase(of: "a"), .awaitingAck(since: t0))
        ledger.expireLostAcks(now: t0.addingTimeInterval(120))
        XCTAssertEqual(ledger.phase(of: "a"), .queued)
    }

    func testRepeatedLostAcksEndInStuck() {
        var ledger = ledger(["a"])
        var now = t0
        for _ in 0..<WatchSyncLedger.Policy.standard.maxAttempts {
            _ = ledger.nextToStart(now: now)
            ledger.markHandedOff(stem: "a", now: now)
            now = now.addingTimeInterval(121)
            ledger.expireLostAcks(now: now)
        }
        XCTAssertEqual(ledger.phase(of: "a"), .stuck(attempts: WatchSyncLedger.Policy.standard.maxAttempts))
    }

    func testUpdatingBytesKeepsPhaseAndAttempts() {
        var ledger = ledger(["a"])
        _ = ledger.nextToStart(now: t0)
        ledger.markFailed(stem: "a", failure: .transient, now: t0)
        ledger.updateBytes(stem: "a", bytes: 1)
        XCTAssertEqual(ledger.phase(of: "a"), .waiting(until: t0.addingTimeInterval(20), attempts: 1))
        ledger.updateBytes(stem: "unknown", bytes: 5)
        XCTAssertNil(ledger.phase(of: "unknown"))
    }

    func testAbandonedPreparationReturnsToTheQueueWithoutAnAttempt() {
        var ledger = ledger(["a", "b"])
        _ = ledger.nextToStart(now: t0)
        ledger.markSending(stem: "b", fraction: 0.5)
        ledger.abandonPreparation(stem: "a")
        ledger.abandonPreparation(stem: "b")
        XCTAssertEqual(ledger.phase(of: "a"), .queued)
        XCTAssertEqual(ledger.phase(of: "b"), .sending(fraction: 0.5))
        XCTAssertEqual(ledger.nextToStart(now: t0), ["a"])
    }
}
