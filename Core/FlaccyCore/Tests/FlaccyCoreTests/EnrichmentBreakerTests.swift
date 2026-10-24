import XCTest
@testable import FlaccyCore

final class EnrichmentBreakerTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_791_815_331)
    private let threshold = EnrichmentPolicy.transportFailuresBeforeWaiting

    private func observe(
        _ breaker: inout EnrichmentBreaker, _ observation: EnrichmentBreaker.Observation, times: Int
    ) -> [EnrichmentBreaker.Verdict] {
        (0..<times).map { _ in breaker.observe(observation, now: now) }
    }

    func testProgressAlwaysCarriesOn() {
        var breaker = EnrichmentBreaker()
        XCTAssertEqual(breaker.observe(.progress, now: now), .carryOn)
    }

    func testSilenceParksThePassOnTheFifthAttemptRunning() {
        var breaker = EnrichmentBreaker()
        let verdicts = observe(&breaker, .transport, times: threshold)
        XCTAssertEqual(Array(verdicts.dropLast()), Array(repeating: .carryOn, count: threshold - 1))
        XCTAssertEqual(verdicts.last, .waitForNetwork)
    }

    func testAnAnsweredAttemptClearsTheRunOfSilence() {
        var breaker = EnrichmentBreaker()
        _ = observe(&breaker, .transport, times: threshold - 1)
        XCTAssertEqual(breaker.observe(.progress, now: now), .carryOn)
        XCTAssertEqual(observe(&breaker, .transport, times: threshold - 1), Array(repeating: .carryOn, count: threshold - 1))
    }

    func testErrorAnswersGiveTheServiceABreatherAfterTheSameRun() {
        var breaker = EnrichmentBreaker()
        let verdicts = observe(&breaker, .serviceError, times: threshold)
        XCTAssertEqual(Array(verdicts.dropLast()), Array(repeating: .carryOn, count: threshold - 1))
        XCTAssertEqual(
            verdicts.last,
            .pause(.serviceUnavailable, until: now.addingTimeInterval(EnrichmentPolicy.serviceRetryInterval))
        )
    }

    func testRunsOfDifferentKindsDoNotAddUp() {
        var breaker = EnrichmentBreaker()
        for _ in 0..<(threshold - 1) {
            XCTAssertEqual(breaker.observe(.transport, now: now), .carryOn)
            XCTAssertEqual(breaker.observe(.serviceError, now: now), .carryOn)
        }
    }

    func testASpentAllowanceStopsTheScopeOnTheFirstSign() {
        var breaker = EnrichmentBreaker()
        let resets = now.addingTimeInterval(31_000)
        XCTAssertEqual(
            breaker.observe(.quotaReached(resetsAt: resets), now: now),
            .pause(.dailyLimit, until: resets)
        )
    }

    func testASpentAllowanceNeedsNoRunUpAfterEarlierSuccesses() {
        var breaker = EnrichmentBreaker()
        _ = observe(&breaker, .progress, times: 40)
        let resets = now.addingTimeInterval(120)
        XCTAssertEqual(
            breaker.observe(.quotaReached(resetsAt: resets), now: now),
            .pause(.dailyLimit, until: resets)
        )
    }

    func testMissingEntitlementStopsTheScopeAndLeavesTheRunsAlone() {
        var breaker = EnrichmentBreaker()
        _ = observe(&breaker, .transport, times: threshold - 1)
        XCTAssertEqual(breaker.observe(.unauthorized, now: now), .needsEntitlement)
        XCTAssertEqual(breaker.observe(.transport, now: now), .waitForNetwork)
    }

    func testResetStartsAScopeWithACleanSlate() {
        var breaker = EnrichmentBreaker()
        _ = observe(&breaker, .transport, times: threshold - 1)
        _ = observe(&breaker, .serviceError, times: threshold - 1)
        breaker.reset()
        XCTAssertEqual(observe(&breaker, .transport, times: threshold - 1), Array(repeating: .carryOn, count: threshold - 1))
        breaker.reset()
        XCTAssertEqual(observe(&breaker, .serviceError, times: threshold - 1), Array(repeating: .carryOn, count: threshold - 1))
    }

    func testFurtherSilenceAfterParkingKeepsSayingWait() {
        var breaker = EnrichmentBreaker()
        _ = observe(&breaker, .transport, times: threshold)
        XCTAssertEqual(breaker.observe(.transport, now: now), .waitForNetwork)
    }
}
