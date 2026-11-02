import XCTest
@testable import FlaccyCore

final class RequestGateTests: XCTestCase {

    private let gap: TimeInterval = 0.4
    private let now = Date(timeIntervalSince1970: 1_000)
    private let patience: TimeInterval = 3

    private func wait(_ claim: RequestGate.Claim, file: StaticString = #filePath, line: UInt = #line) -> TimeInterval {
        guard case .after(let seconds) = claim else {
            XCTFail("expected a slot, got \(claim)", file: file, line: line)
            return -1
        }
        return seconds
    }

    func testRequestsLeaveAGapWhoeverSendsThem() {
        var gate = RequestGate(gap: gap)
        XCTAssertEqual(wait(gate.claim(now: now, patience: patience)), 0, accuracy: 0.001)
        XCTAssertEqual(wait(gate.claim(now: now, patience: patience)), 0.4, accuracy: 0.001)
        XCTAssertEqual(wait(gate.claim(now: now, patience: patience)), 0.8, accuracy: 0.001)
        XCTAssertEqual(wait(gate.claim(now: now.addingTimeInterval(10), patience: patience)), 0, accuracy: 0.001)
    }

    func testACooldownHoldsEveryRequestUntilItEnds() {
        var gate = RequestGate(gap: gap)
        gate.throttled(now: now, retryAfter: 2, jitter: 0)
        XCTAssertEqual(gate.claim(now: now, patience: patience), .after(2))
        XCTAssertEqual(gate.cooldownLeft(now: now), 2)
        XCTAssertEqual(gate.cooldownLeft(now: now.addingTimeInterval(5)), 0)
    }

    func testACallerWithLittlePatienceIsToldNotToSend() {
        var gate = RequestGate(gap: gap)
        gate.throttled(now: now, retryAfter: 60, jitter: 0)
        XCTAssertEqual(gate.claim(now: now, patience: patience), .cooling(60))
        XCTAssertEqual(gate.claim(now: now, patience: 120), .after(60))
    }

    func testJitterStretchesACooldownByUpToThirtyPercentAndNeverShortensOne() {
        var gate = RequestGate(gap: gap)
        gate.throttled(now: now, retryAfter: 10, jitter: 1)
        XCTAssertEqual(gate.cooldownLeft(now: now), 13, accuracy: 0.0001)
        gate.throttled(now: now, retryAfter: 1, jitter: 0)
        XCTAssertEqual(gate.cooldownLeft(now: now), 13, accuracy: 0.0001)
    }

    func testARefusalRestsTheLaneAtOnceAndAHiccupNeedsThree() {
        var refused = LaneBreaker()
        refused.failed(.throttled, now: now, jitter: 0)
        XCTAssertEqual(refused.restLeft(now: now), 300)

        var hiccups = LaneBreaker()
        hiccups.failed(.transient, now: now, jitter: 0)
        hiccups.failed(.transient, now: now, jitter: 0)
        XCTAssertEqual(hiccups.restLeft(now: now), 0)
        hiccups.failed(.transient, now: now, jitter: 0)
        XCTAssertEqual(hiccups.restLeft(now: now), 120)
    }

    func testABusyAnswerNeedsEightInARowAndThenRestsBriefly() {
        var busy = LaneBreaker()
        for _ in 0..<7 { busy.failed(.busy, now: now, jitter: 0) }
        XCTAssertEqual(busy.restLeft(now: now), 0)
        busy.failed(.busy, now: now, jitter: 0)
        XCTAssertEqual(busy.restLeft(now: now), 30)
        busy.failed(.busy, now: now, jitter: 0)
        XCTAssertEqual(busy.restLeft(now: now), 60)
        busy.succeeded()
        XCTAssertEqual(busy.restLeft(now: now), 0)
    }

    func testRestsLengthenAndASuccessEndsThem() {
        var breaker = LaneBreaker()
        breaker.failed(.throttled, now: now, jitter: 0)
        breaker.failed(.throttled, now: now, jitter: 0)
        XCTAssertEqual(breaker.restLeft(now: now), 600)
        XCTAssertEqual(breaker.last, .throttled)
        breaker.succeeded()
        XCTAssertEqual(breaker.restLeft(now: now), 0)
        XCTAssertNil(breaker.last)
    }
}
