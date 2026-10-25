import XCTest
@testable import FlaccyCore

final class WatchSyncLedgerTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let mib: Int64 = 1_024 * 1_024

    private func ledger(_ stems: [String], bytes: Int64 = 10 * 1_024 * 1_024, policy: WatchSyncLedger.Policy = .standard) -> WatchSyncLedger {
        var ledger = WatchSyncLedger(policy: policy)
        ledger.request(stems.map { (stem: $0, bytes: bytes) }, now: t0)
        return ledger
    }

    private func ingest(_ ledger: inout WatchSyncLedger, _ confirmed: Set<String> = [], full: Bool = false, now: Date? = nil) {
        ledger.ingest(confirmed: confirmed, watchFreeBytes: 1_000, watchIsFull: full, now: now ?? t0)
    }

    func testPolicyStandardValues() {
        let policy = WatchSyncLedger.Policy.standard
        XCTAssertEqual(policy.maxInFlightCount, 4)
        XCTAssertEqual(policy.maxInFlightBytes, 150 * mib)
        XCTAssertEqual(policy.backoffBase, 20)
        XCTAssertEqual(policy.backoffFactor, 3)
        XCTAssertEqual(policy.backoffCap, 900)
        XCTAssertEqual(policy.maxAttempts, 8)
        XCTAssertEqual(policy.ackGrace, 120)
    }

    func testRequestQueuesNewStems() {
        let ledger = ledger(["a", "b"])
        XCTAssertEqual(ledger.phase(of: "a"), .queued)
        XCTAssertEqual(ledger.phase(of: "b"), .queued)
        XCTAssertNil(ledger.phase(of: "c"))
        XCTAssertEqual(ledger.requested, ["a", "b"])
        XCTAssertEqual(ledger.queuedCount, 2)
        XCTAssertEqual(ledger.unconfirmedCount, 2)
        XCTAssertTrue(ledger.isBusy)
    }

    func testEmptyLedgerIsIdle() {
        let ledger = WatchSyncLedger()
        XCTAssertFalse(ledger.isBusy)
        XCTAssertEqual(ledger.syncedCount, 0)
        XCTAssertEqual(ledger.unconfirmedCount, 0)
        XCTAssertNil(ledger.nextWakeUp(now: t0))
    }

    func testRequestKeepsOnWatchStemOnWatch() {
        var ledger = ledger(["a"])
        ingest(&ledger, ["a"])
        ledger.request([(stem: "a", bytes: 5)], now: t0)
        XCTAssertEqual(ledger.phase(of: "a"), .onWatch)
        XCTAssertTrue(ledger.isOnWatch("a"))
    }

    func testRerequestResetsAttemptsAndRequeues() {
        var ledger = ledger(["a"])
        _ = ledger.nextToStart(now: t0)
        ledger.markFailed(stem: "a", failure: .transient, now: t0)
        XCTAssertEqual(ledger.phase(of: "a"), .waiting(until: t0.addingTimeInterval(20), attempts: 1))
        ledger.request([(stem: "a", bytes: 10)], now: t0)
        XCTAssertEqual(ledger.phase(of: "a"), .queued)
        _ = ledger.nextToStart(now: t0)
        ledger.markFailed(stem: "a", failure: .transient, now: t0)
        XCTAssertEqual(ledger.phase(of: "a"), .waiting(until: t0.addingTimeInterval(20), attempts: 1))
    }

    func testRerequestOfStuckAndDiskFullRequeues() {
        var ledger = ledger(["a", "b"], policy: .init(maxAttempts: 1))
        _ = ledger.nextToStart(now: t0)
        ledger.markFailed(stem: "a", failure: .transient, now: t0)
        ledger.markFailed(stem: "b", failure: .diskFull, now: t0)
        XCTAssertEqual(ledger.phase(of: "a"), .stuck(attempts: 1))
        XCTAssertEqual(ledger.phase(of: "b"), .diskFull)
        ledger.request([(stem: "a", bytes: 1), (stem: "b", bytes: 1)], now: t0)
        XCTAssertEqual(ledger.phase(of: "a"), .queued)
        XCTAssertEqual(ledger.phase(of: "b"), .queued)
    }

    func testRerequestOfInFlightStemLeavesItAlone() {
        var ledger = ledger(["a"])
        _ = ledger.nextToStart(now: t0)
        ledger.markSending(stem: "a", fraction: 0.5)
        ledger.request([(stem: "a", bytes: 10)], now: t0)
        XCTAssertEqual(ledger.phase(of: "a"), .sending(fraction: 0.5))
        ledger.markHandedOff(stem: "a", now: t0)
        ledger.request([(stem: "a", bytes: 10)], now: t0)
        XCTAssertEqual(ledger.phase(of: "a"), .awaitingAck(since: t0))
    }

    func testNextToStartLimitsByCount() {
        var ledger = ledger(["a", "b", "c", "d", "e", "f"], bytes: 1)
        XCTAssertEqual(ledger.nextToStart(now: t0), ["a", "b", "c", "d"])
        XCTAssertEqual(ledger.inFlightCount, 4)
        XCTAssertEqual(ledger.nextToStart(now: t0), [])
        ledger.markHandedOff(stem: "a", now: t0)
        XCTAssertEqual(ledger.nextToStart(now: t0), ["e"])
        XCTAssertEqual(ledger.queuedCount, 1)
    }

    func testNextToStartLimitsByBytes() {
        var ledger = ledger(["a", "b", "c", "d"], bytes: 60 * mib)
        XCTAssertEqual(ledger.nextToStart(now: t0), ["a", "b"])
        XCTAssertEqual(ledger.nextToStart(now: t0), [])
        ledger.markHandedOff(stem: "b", now: t0)
        XCTAssertEqual(ledger.nextToStart(now: t0), ["c"])
    }

    func testBytesBudgetIsInclusive() {
        var ledger = ledger(["a", "b", "c"], bytes: 50 * mib)
        XCTAssertEqual(ledger.nextToStart(now: t0), ["a", "b", "c"])
    }

    func testOversizedFirstItemIsAdmittedWhenNothingInFlight() {
        var ledger = WatchSyncLedger()
        ledger.request([(stem: "big", bytes: 400 * mib), (stem: "small", bytes: 1 * mib)], now: t0)
        XCTAssertEqual(ledger.nextToStart(now: t0), ["big"])
        XCTAssertEqual(ledger.nextToStart(now: t0), [])
    }

    func testOversizedItemWaitsBehindInFlightWork() {
        var ledger = WatchSyncLedger()
        ledger.request([(stem: "small", bytes: 1 * mib), (stem: "big", bytes: 400 * mib)], now: t0)
        XCTAssertEqual(ledger.nextToStart(now: t0), ["small"])
        XCTAssertEqual(ledger.nextToStart(now: t0), [])
        ledger.markHandedOff(stem: "small", now: t0)
        XCTAssertEqual(ledger.nextToStart(now: t0), ["big"])
    }

    func testAdmissionNeverOvertakesAStemThatDoesNotFit() {
        var ledger = WatchSyncLedger()
        ledger.request(
            [(stem: "a", bytes: 100 * mib), (stem: "b", bytes: 100 * mib), (stem: "c", bytes: 1 * mib)],
            now: t0
        )
        XCTAssertEqual(ledger.nextToStart(now: t0), ["a"])
        XCTAssertEqual(ledger.nextToStart(now: t0), [])
    }

    func testRequestOrderIsPreservedNotAlphabetical() {
        var ledger = WatchSyncLedger()
        ledger.request([(stem: "z", bytes: 1), (stem: "m", bytes: 1), (stem: "a", bytes: 1)], now: t0)
        ledger.request([(stem: "b", bytes: 1)], now: t0)
        XCTAssertEqual(ledger.nextToStart(now: t0), ["z", "m", "a", "b"])
    }

    func testRerequestKeepsOriginalPlaceInLine() {
        var ledger = WatchSyncLedger(policy: .init(maxInFlightCount: 1))
        ledger.request([(stem: "z", bytes: 1), (stem: "a", bytes: 1)], now: t0)
        ledger.request([(stem: "z", bytes: 1)], now: t0)
        XCTAssertEqual(ledger.nextToStart(now: t0), ["z"])
    }

    func testWaitingStemsStartOnlyOnceBackoffElapsed() {
        var ledger = ledger(["a", "b"], bytes: 1)
        _ = ledger.nextToStart(now: t0)
        ledger.markFailed(stem: "a", failure: .transient, now: t0)
        ledger.markHandedOff(stem: "b", now: t0)
        XCTAssertEqual(ledger.nextToStart(now: t0.addingTimeInterval(19)), [])
        XCTAssertEqual(ledger.nextToStart(now: t0.addingTimeInterval(20)), ["a"])
        XCTAssertEqual(ledger.phase(of: "a"), .preparing)
    }

    func testWaitingAndQueuedKeepRequestOrder() {
        var ledger = ledger(["a", "b", "c"], bytes: 1)
        _ = ledger.nextToStart(now: t0)
        ledger.markFailed(stem: "b", failure: .transient, now: t0)
        ledger.markHandedOff(stem: "a", now: t0)
        ledger.markHandedOff(stem: "c", now: t0)
        ledger.request([(stem: "d", bytes: 1)], now: t0)
        XCTAssertEqual(ledger.nextToStart(now: t0.addingTimeInterval(100)), ["b", "d"])
    }

    func testDiskFullAndStuckAreNotStarted() {
        var ledger = ledger(["a", "b"], bytes: 1)
        _ = ledger.nextToStart(now: t0)
        ledger.markFailed(stem: "a", failure: .diskFull, now: t0)
        ledger.markFailed(stem: "b", failure: .diskFull, now: t0)
        XCTAssertEqual(ledger.nextToStart(now: t0.addingTimeInterval(10_000)), [])
    }

    func testMarkSendingClamps() {
        var ledger = ledger(["a"])
        _ = ledger.nextToStart(now: t0)
        ledger.markSending(stem: "a", fraction: 1.7)
        XCTAssertEqual(ledger.phase(of: "a"), .sending(fraction: 1))
        ledger.markSending(stem: "a", fraction: -0.4)
        XCTAssertEqual(ledger.phase(of: "a"), .sending(fraction: 0))
        ledger.markSending(stem: "a", fraction: .nan)
        XCTAssertEqual(ledger.phase(of: "a"), .sending(fraction: 0))
        ledger.markSending(stem: "a", fraction: 0.25)
        XCTAssertEqual(ledger.phase(of: "a"), .sending(fraction: 0.25))
    }

    func testMarkSendingIgnoredOutsidePreparingAndSending() {
        var ledger = ledger(["a"])
        ledger.markSending(stem: "a", fraction: 0.5)
        XCTAssertEqual(ledger.phase(of: "a"), .queued)
        _ = ledger.nextToStart(now: t0)
        ledger.markHandedOff(stem: "a", now: t0)
        ledger.markSending(stem: "a", fraction: 0.5)
        XCTAssertEqual(ledger.phase(of: "a"), .awaitingAck(since: t0))
        ledger.markSending(stem: "ghost", fraction: 0.5)
        XCTAssertNil(ledger.phase(of: "ghost"))
    }

    func testMarkHandedOffFromPreparingAndSendingOnly() {
        var ledger = ledger(["a", "b"])
        ledger.markHandedOff(stem: "a", now: t0)
        XCTAssertEqual(ledger.phase(of: "a"), .queued)
        _ = ledger.nextToStart(now: t0)
        ledger.markHandedOff(stem: "a", now: t0)
        XCTAssertEqual(ledger.phase(of: "a"), .awaitingAck(since: t0))
        ledger.markSending(stem: "b", fraction: 0.9)
        let later = t0.addingTimeInterval(5)
        ledger.markHandedOff(stem: "b", now: later)
        XCTAssertEqual(ledger.phase(of: "b"), .awaitingAck(since: later))
        XCTAssertEqual(ledger.awaitingAckCount, 2)
        XCTAssertEqual(ledger.inFlightCount, 0)
    }

    func testBackoffSchedule() {
        var ledger = ledger(["a"], bytes: 1, policy: .init(maxAttempts: 100))
        var now = t0
        var delays: [TimeInterval] = []
        for _ in 0..<8 {
            _ = ledger.nextToStart(now: now.addingTimeInterval(10_000))
            now = now.addingTimeInterval(10_000)
            ledger.markFailed(stem: "a", failure: .transient, now: now)
            guard case .waiting(let until, _) = ledger.phase(of: "a") else { return XCTFail("not waiting") }
            delays.append(until.timeIntervalSince(now))
        }
        XCTAssertEqual(delays, [20, 60, 180, 540, 900, 900, 900, 900])
    }

    func testWaitingReportsAttemptCount() {
        var ledger = ledger(["a"], bytes: 1)
        _ = ledger.nextToStart(now: t0)
        ledger.markFailed(stem: "a", failure: .transient, now: t0)
        _ = ledger.nextToStart(now: t0.addingTimeInterval(20))
        ledger.markFailed(stem: "a", failure: .transient, now: t0)
        XCTAssertEqual(ledger.phase(of: "a"), .waiting(until: t0.addingTimeInterval(60), attempts: 2))
    }

    func testStuckAfterMaxAttempts() {
        var ledger = ledger(["a"], bytes: 1)
        var now = t0
        for attempt in 1...8 {
            _ = ledger.nextToStart(now: now)
            ledger.markFailed(stem: "a", failure: .transient, now: now)
            if attempt < 8 {
                guard case .waiting(_, let attempts) = ledger.phase(of: "a") else { return XCTFail("attempt \(attempt)") }
                XCTAssertEqual(attempts, attempt)
                now = now.addingTimeInterval(10_000)
            }
        }
        XCTAssertEqual(ledger.phase(of: "a"), .stuck(attempts: 8))
        XCTAssertEqual(ledger.stuckCount, 1)
        XCTAssertEqual(ledger.nextToStart(now: now.addingTimeInterval(1_000_000)), [])
        XCTAssertNil(ledger.nextWakeUp(now: now))
    }

    func testRetryStuckRequeuesWithFreshAttempts() {
        var ledger = ledger(["a", "b"], bytes: 1, policy: .init(maxAttempts: 2))
        _ = ledger.nextToStart(now: t0)
        ledger.markFailed(stem: "a", failure: .transient, now: t0)
        ledger.markFailed(stem: "a", failure: .transient, now: t0)
        ledger.markFailed(stem: "b", failure: .diskFull, now: t0)
        XCTAssertEqual(ledger.stuckCount, 1)
        XCTAssertEqual(ledger.diskFullCount, 1)
        ledger.retryStuck(now: t0)
        XCTAssertEqual(ledger.phase(of: "a"), .queued)
        XCTAssertEqual(ledger.phase(of: "b"), .queued)
        XCTAssertEqual(ledger.stuckCount, 0)
        _ = ledger.nextToStart(now: t0)
        ledger.markFailed(stem: "a", failure: .transient, now: t0)
        XCTAssertEqual(ledger.phase(of: "a"), .waiting(until: t0.addingTimeInterval(20), attempts: 1))
    }

    func testRetryStuckLeavesOtherPhasesAlone() {
        var ledger = ledger(["a", "b"], bytes: 1)
        _ = ledger.nextToStart(now: t0)
        ledger.markSending(stem: "a", fraction: 0.4)
        ledger.retryStuck(now: t0)
        XCTAssertEqual(ledger.phase(of: "a"), .sending(fraction: 0.4))
        XCTAssertEqual(ledger.phase(of: "b"), .preparing)
    }

    func testDiskFullRecoversOnIngestWhenWatchNoLongerFull() {
        var ledger = ledger(["a"], bytes: 1)
        _ = ledger.nextToStart(now: t0)
        ledger.markFailed(stem: "a", failure: .diskFull, now: t0)
        ingest(&ledger, [], full: true)
        XCTAssertEqual(ledger.phase(of: "a"), .diskFull)
        XCTAssertTrue(ledger.watchIsFull)
        ingest(&ledger, [], full: false)
        XCTAssertEqual(ledger.phase(of: "a"), .queued)
        XCTAssertFalse(ledger.watchIsFull)
        XCTAssertEqual(ledger.watchFreeBytes, 1_000)
    }

    func testIngestClearsEveryTransitionalPhaseForConfirmedStems() {
        var ledger = ledger(["pre", "send", "ack", "wait", "full", "stuck", "queued"], bytes: 1, policy: .init(maxInFlightCount: 20, maxAttempts: 1))
        _ = ledger.nextToStart(now: t0)
        ledger.markSending(stem: "send", fraction: 0.3)
        ledger.markHandedOff(stem: "ack", now: t0)
        ledger.markFailed(stem: "full", failure: .diskFull, now: t0)
        ledger.markFailed(stem: "stuck", failure: .transient, now: t0)
        let all: Set<String> = ["pre", "send", "ack", "wait", "full", "stuck", "queued"]
        ingest(&ledger, all)
        for stem in all { XCTAssertEqual(ledger.phase(of: stem), .onWatch, stem) }
        XCTAssertEqual(ledger.syncedCount, 7)
        XCTAssertEqual(ledger.inFlightCount, 0)
        XCTAssertEqual(ledger.awaitingAckCount, 0)
        XCTAssertEqual(ledger.queuedCount, 0)
        XCTAssertEqual(ledger.unconfirmedCount, 0)
        XCTAssertFalse(ledger.isBusy)
        XCTAssertNil(ledger.nextWakeUp(now: t0))
        XCTAssertEqual(ledger.nextToStart(now: t0.addingTimeInterval(100_000)), [])
    }

    func testIngestClearsWaitingBackoffForConfirmedStem() {
        var ledger = ledger(["a"], bytes: 1)
        _ = ledger.nextToStart(now: t0)
        ledger.markFailed(stem: "a", failure: .transient, now: t0)
        ingest(&ledger, ["a"])
        XCTAssertEqual(ledger.phase(of: "a"), .onWatch)
        XCTAssertNil(ledger.nextWakeUp(now: t0))
    }

    func testConfirmedButNeverRequestedStemsAreTrackedOnWatch() {
        var ledger = WatchSyncLedger()
        ingest(&ledger, ["held"])
        XCTAssertEqual(ledger.phase(of: "held"), .onWatch)
        XCTAssertEqual(ledger.syncedCount, 1)
        XCTAssertEqual(ledger.requested, [])
        XCTAssertEqual(ledger.unconfirmedCount, 0)
    }

    func testUnrequestedStemThatLeavesTheWatchIsForgotten() {
        var ledger = WatchSyncLedger()
        ingest(&ledger, ["held"])
        ingest(&ledger, [])
        XCTAssertNil(ledger.phase(of: "held"))
        XCTAssertEqual(ledger.syncedCount, 0)
    }

    func testRequestingAStemTheWatchAlreadyHoldsAdoptsItAsRequested() {
        var ledger = WatchSyncLedger()
        ingest(&ledger, ["held"])
        ledger.request([(stem: "held", bytes: 3)], now: t0)
        XCTAssertEqual(ledger.phase(of: "held"), .onWatch)
        XCTAssertEqual(ledger.requested, ["held"])
        ingest(&ledger, [])
        XCTAssertEqual(ledger.phase(of: "held"), .queued)
    }

    func testDeletedOnWatchGoesBackToQueued() {
        var ledger = ledger(["a", "b"])
        ingest(&ledger, ["a", "b"])
        ingest(&ledger, ["b"])
        XCTAssertEqual(ledger.phase(of: "a"), .queued)
        XCTAssertEqual(ledger.phase(of: "b"), .onWatch)
        XCTAssertEqual(ledger.nextToStart(now: t0), ["a"])
    }

    func testUnconfirmedInFlightStemsAreLeftAlone() {
        var ledger = ledger(["a", "b", "c"], bytes: 1)
        _ = ledger.nextToStart(now: t0)
        ledger.markSending(stem: "b", fraction: 0.6)
        ledger.markHandedOff(stem: "c", now: t0)
        ingest(&ledger, [], now: t0.addingTimeInterval(60))
        XCTAssertEqual(ledger.phase(of: "a"), .preparing)
        XCTAssertEqual(ledger.phase(of: "b"), .sending(fraction: 0.6))
        XCTAssertEqual(ledger.phase(of: "c"), .awaitingAck(since: t0))
    }

    func testAckGraceExpiryRequeuesAndCountsOneFailure() {
        var ledger = ledger(["a"], bytes: 1)
        _ = ledger.nextToStart(now: t0)
        ledger.markHandedOff(stem: "a", now: t0)
        ingest(&ledger, [], now: t0.addingTimeInterval(119))
        XCTAssertEqual(ledger.phase(of: "a"), .awaitingAck(since: t0))
        ingest(&ledger, [], now: t0.addingTimeInterval(120))
        XCTAssertEqual(ledger.phase(of: "a"), .queued)
        _ = ledger.nextToStart(now: t0)
        ledger.markFailed(stem: "a", failure: .transient, now: t0)
        XCTAssertEqual(ledger.phase(of: "a"), .waiting(until: t0.addingTimeInterval(60), attempts: 2))
    }

    func testRepeatedAckExpiryEventuallyGetsStuck() {
        var ledger = ledger(["a"], bytes: 1, policy: .init(maxAttempts: 2))
        var now = t0
        for _ in 0..<2 {
            _ = ledger.nextToStart(now: now)
            ledger.markHandedOff(stem: "a", now: now)
            now = now.addingTimeInterval(200)
            ingest(&ledger, [], now: now)
        }
        XCTAssertEqual(ledger.phase(of: "a"), .stuck(attempts: 2))
    }

    func testAckArrivingWithinGraceConfirms() {
        var ledger = ledger(["a"], bytes: 1)
        _ = ledger.nextToStart(now: t0)
        ledger.markHandedOff(stem: "a", now: t0)
        ingest(&ledger, ["a"], now: t0.addingTimeInterval(30))
        XCTAssertEqual(ledger.phase(of: "a"), .onWatch)
    }

    func testMarkFailedIgnoresOnWatchAndUnknownStems() {
        var ledger = ledger(["a"])
        ingest(&ledger, ["a"])
        ledger.markFailed(stem: "a", failure: .transient, now: t0)
        ledger.markFailed(stem: "a", failure: .diskFull, now: t0)
        ledger.markFailed(stem: "ghost", failure: .transient, now: t0)
        XCTAssertEqual(ledger.phase(of: "a"), .onWatch)
        XCTAssertNil(ledger.phase(of: "ghost"))
    }

    func testNextWakeUpIsEarliestOfBackoffAndAckGrace() {
        var ledger = ledger(["a", "b", "c"], bytes: 1)
        _ = ledger.nextToStart(now: t0)
        ledger.markFailed(stem: "a", failure: .transient, now: t0)
        ledger.markHandedOff(stem: "b", now: t0.addingTimeInterval(10))
        ledger.markHandedOff(stem: "c", now: t0.addingTimeInterval(5))
        XCTAssertEqual(ledger.nextWakeUp(now: t0), t0.addingTimeInterval(20))
        _ = ledger.nextToStart(now: t0.addingTimeInterval(20))
        XCTAssertEqual(ledger.nextWakeUp(now: t0), t0.addingTimeInterval(125))
    }

    func testWithdrawForgetsEverything() {
        var ledger = ledger(["a", "b", "c"], bytes: 1)
        _ = ledger.nextToStart(now: t0)
        ledger.markHandedOff(stem: "b", now: t0)
        ingest(&ledger, ["c"])
        ledger.withdraw(["a", "b", "c", "ghost"])
        XCTAssertNil(ledger.phase(of: "a"))
        XCTAssertNil(ledger.phase(of: "b"))
        XCTAssertNil(ledger.phase(of: "c"))
        XCTAssertEqual(ledger.requested, [])
        XCTAssertFalse(ledger.isBusy)
        XCTAssertEqual(ledger.syncedCount, 0)
        XCTAssertNil(ledger.nextWakeUp(now: t0))
    }

    func testWithdrawnStemIsNotRevivedByAnOldConfirmation() {
        var ledger = ledger(["a"])
        ledger.withdraw(["a"])
        XCTAssertEqual(ledger.requested, [])
        ingest(&ledger, [])
        XCTAssertNil(ledger.phase(of: "a"))
    }

    func testResetForgetsEverythingIncludingWatchState() {
        var ledger = ledger(["a", "b"])
        ingest(&ledger, ["a"], full: true)
        ledger.reset()
        XCTAssertEqual(ledger.requested, [])
        XCTAssertEqual(ledger.syncedCount, 0)
        XCTAssertFalse(ledger.isBusy)
        XCTAssertEqual(ledger.watchFreeBytes, 0)
        XCTAssertFalse(ledger.watchIsFull)
        XCTAssertEqual(ledger, WatchSyncLedger())
    }

    func testFractionOverStems() {
        var ledger = ledger(["done", "wire", "ack", "queued"], bytes: 1)
        ingest(&ledger, ["done"])
        _ = ledger.nextToStart(now: t0)
        ledger.markSending(stem: "wire", fraction: 0.5)
        ledger.markHandedOff(stem: "ack", now: t0)
        XCTAssertEqual(ledger.fraction(of: ["done", "wire", "ack", "queued"]), (1 + 0.5 + 1 + 0) / 4, accuracy: 1e-9)
        XCTAssertEqual(ledger.fraction(of: ["queued"]), 0)
        XCTAssertEqual(ledger.fraction(of: ["done"]), 1)
        XCTAssertEqual(ledger.fraction(of: ["unknown", "done"]), 0.5, accuracy: 1e-9)
        XCTAssertEqual(ledger.fraction(of: []), 0)
    }

    func testFractionCountsPreparingAndFailedAsZero() {
        var ledger = ledger(["a", "b", "c"], bytes: 1)
        _ = ledger.nextToStart(now: t0)
        ledger.markFailed(stem: "b", failure: .diskFull, now: t0)
        ledger.markFailed(stem: "c", failure: .transient, now: t0)
        XCTAssertEqual(ledger.fraction(of: ["a", "b", "c"]), 0)
    }

    func testCounts() {
        var ledger = ledger(["done", "pre", "send", "ack", "queued", "wait", "full", "stuck"], bytes: 1, policy: .init(maxInFlightCount: 20, maxAttempts: 1))
        ingest(&ledger, ["done"])
        _ = ledger.nextToStart(now: t0)
        ledger.markSending(stem: "send", fraction: 0.1)
        ledger.markHandedOff(stem: "ack", now: t0)
        ledger.markFailed(stem: "full", failure: .diskFull, now: t0)
        ledger.markFailed(stem: "stuck", failure: .transient, now: t0)
        ledger.request([(stem: "queued2", bytes: 1)], now: t0)
        XCTAssertEqual(ledger.syncedCount, 1)
        XCTAssertEqual(ledger.inFlightCount, 4)
        XCTAssertEqual(ledger.awaitingAckCount, 1)
        XCTAssertEqual(ledger.diskFullCount, 1)
        XCTAssertEqual(ledger.stuckCount, 1)
        XCTAssertEqual(ledger.queuedCount, 1)
        XCTAssertEqual(ledger.unconfirmedCount, 8)
        XCTAssertTrue(ledger.isBusy)
    }

    func testWaitingCountsAsQueued() {
        var ledger = ledger(["a"], bytes: 1)
        _ = ledger.nextToStart(now: t0)
        ledger.markFailed(stem: "a", failure: .transient, now: t0)
        XCTAssertEqual(ledger.queuedCount, 1)
        XCTAssertTrue(ledger.isBusy)
    }

    func testStuckAndDiskFullAloneAreNotBusy() {
        var ledger = ledger(["a", "b"], bytes: 1, policy: .init(maxAttempts: 1))
        _ = ledger.nextToStart(now: t0)
        ledger.markFailed(stem: "a", failure: .transient, now: t0)
        ledger.markFailed(stem: "b", failure: .diskFull, now: t0)
        XCTAssertFalse(ledger.isBusy)
    }

    func testRequestedPersistenceRoundTrip() {
        var original = ledger(["x", "y", "z"])
        ingest(&original, ["y"])
        original.withdraw(["z"])
        original.request([(stem: "w", bytes: 1)], now: t0)
        let restored = WatchSyncLedger(requested: original.requested)
        XCTAssertEqual(restored.requested, ["x", "y", "w"])
        XCTAssertEqual(restored.queuedCount, 3)
        XCTAssertEqual(restored.phase(of: "y"), .queued)
    }

    func testRestoredLedgerResolvesAgainstHeartbeat() {
        var restored = WatchSyncLedger(requested: ["a", "b"])
        ingest(&restored, ["a"])
        XCTAssertEqual(restored.phase(of: "a"), .onWatch)
        XCTAssertEqual(restored.phase(of: "b"), .queued)
    }

    func testRestoredLedgerStartsInStableOrder() {
        var restored = WatchSyncLedger(requested: ["c", "a", "b"])
        XCTAssertEqual(restored.nextToStart(now: t0), ["a", "b", "c"])
    }

    func testSupersedingAStemOnTheWatchQueuesItAgain() {
        var ledger = ledger(["a"])
        ingest(&ledger, ["a"])
        ledger.supersede(["a"])
        XCTAssertEqual(ledger.phase(of: "a"), .queued)
        XCTAssertEqual(ledger.superseded, ["a"])
        XCTAssertEqual(ledger.nextToStart(now: t0), ["a"])
    }

    func testSupersededStemIgnoresTheOldCopyUntilTheNewOneIsHandedOff() {
        var ledger = ledger(["a"])
        ingest(&ledger, ["a"])
        ledger.supersede(["a"])
        ingest(&ledger, ["a"])
        XCTAssertEqual(ledger.phase(of: "a"), .queued)
        _ = ledger.nextToStart(now: t0)
        ingest(&ledger, ["a"])
        XCTAssertEqual(ledger.phase(of: "a"), .preparing)
        ledger.markSending(stem: "a", fraction: 0.4)
        ingest(&ledger, ["a"])
        XCTAssertEqual(ledger.phase(of: "a"), .sending(fraction: 0.4))
        ledger.markHandedOff(stem: "a", now: t0)
        XCTAssertEqual(ledger.phase(of: "a"), .awaitingAck(since: t0))
        XCTAssertTrue(ledger.superseded.isEmpty)
        ingest(&ledger, ["a"])
        XCTAssertEqual(ledger.phase(of: "a"), .onWatch)
    }

    func testSupersedingAStemInFlightSendsItAgainOnceTheOldTransferIsConfirmed() {
        var ledger = ledger(["a"])
        _ = ledger.nextToStart(now: t0)
        ledger.markSending(stem: "a", fraction: 0.5)
        ledger.markHandedOff(stem: "a", now: t0)
        ledger.supersede(["a"])
        XCTAssertEqual(ledger.phase(of: "a"), .awaitingAck(since: t0))
        XCTAssertEqual(ledger.superseded, ["a"])
        ingest(&ledger, ["a"])
        XCTAssertEqual(ledger.phase(of: "a"), .queued)
        XCTAssertEqual(ledger.nextToStart(now: t0), ["a"])
        ingest(&ledger, ["a"])
        XCTAssertEqual(ledger.phase(of: "a"), .preparing)
    }

    func testSupersedingAPreparingStemThatFailsIgnoresTheOldCopyAfterwards() {
        var ledger = ledger(["a"])
        _ = ledger.nextToStart(now: t0)
        ledger.supersede(["a"])
        ledger.markFailed(stem: "a", failure: .transient, now: t0)
        ingest(&ledger, ["a"])
        XCTAssertNotEqual(ledger.phase(of: "a"), .onWatch)
        XCTAssertEqual(ledger.superseded, ["a"])
    }

    func testSupersedingAStemThatWasNeverSentChangesNothing() {
        var ledger = ledger(["a"])
        let before = ledger
        ledger.supersede(["a"])
        XCTAssertEqual(ledger, before)
        XCTAssertTrue(ledger.superseded.isEmpty)
    }

    func testSupersedingIgnoresStemsThePersonNeverRequested() {
        var ledger = WatchSyncLedger()
        ingest(&ledger, ["watch-only"])
        ledger.supersede(["watch-only", "unknown"])
        XCTAssertEqual(ledger.phase(of: "watch-only"), .onWatch)
        XCTAssertNil(ledger.phase(of: "unknown"))
        XCTAssertTrue(ledger.superseded.isEmpty)
    }

    func testSupersededStemsSurviveARelaunch() {
        var original = ledger(["a", "b"])
        ingest(&original, ["a", "b"])
        original.supersede(["a"])
        var restored = WatchSyncLedger(requested: original.requested, superseded: original.superseded)
        XCTAssertEqual(restored.superseded, ["a"])
        ingest(&restored, ["a", "b"])
        XCTAssertEqual(restored.phase(of: "a"), .queued)
        XCTAssertEqual(restored.phase(of: "b"), .onWatch)
    }

    func testAdoptingATransferForASupersededStemIsRefused() {
        var ledger = ledger(["a"])
        ingest(&ledger, ["a"])
        ledger.supersede(["a"])
        XCTAssertFalse(ledger.adopt(stem: "a", bytes: 10, fraction: 0.2))
        XCTAssertEqual(ledger.phase(of: "a"), .queued)
    }

    func testWithdrawingASupersededStemForgetsIt() {
        var ledger = ledger(["a"])
        ingest(&ledger, ["a"])
        ledger.supersede(["a"])
        ledger.withdraw(["a"])
        XCTAssertTrue(ledger.superseded.isEmpty)
        XCTAssertNil(ledger.phase(of: "a"))
    }

    func testEquatable() {
        XCTAssertEqual(ledger(["a", "b"]), ledger(["a", "b"]))
        XCTAssertNotEqual(ledger(["a", "b"]), ledger(["a"]))
        var changed = ledger(["a"])
        _ = changed.nextToStart(now: t0)
        XCTAssertNotEqual(changed, ledger(["a"]))
        XCTAssertNotEqual(ledger(["a"]), ledger(["a"], policy: .init(maxInFlightCount: 1)))
    }

    func testIsDeterministic() {
        func run() -> [String] {
            var ledger = WatchSyncLedger()
            ledger.request((0..<30).map { (stem: "s\($0)", bytes: Int64(($0 % 5 + 1)) * mib) }, now: t0)
            var order: [String] = []
            var confirmed = Set<String>()
            for step in 0..<40 {
                let now = t0.addingTimeInterval(Double(step))
                let started = ledger.nextToStart(now: now)
                order += started
                for stem in started { ledger.markHandedOff(stem: stem, now: now) }
                confirmed.formUnion(started)
                ledger.ingest(confirmed: confirmed, watchFreeBytes: 0, watchIsFull: false, now: now)
            }
            return order
        }
        XCTAssertEqual(run(), run())
        XCTAssertEqual(run(), (0..<30).map { "s\($0)" })
    }
}
