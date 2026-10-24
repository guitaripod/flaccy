import XCTest
@testable import FlaccyCore

final class AIProxyReplyTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_791_815_331)

    private func classify(_ status: Int, _ code: String? = nil, retryAfter: TimeInterval? = nil) -> AIProxyReply {
        AIProxyReply.classify(status: status, errorCode: code, retryAfter: retryAfter, now: now)
    }

    func testSuccessIsAnAnswer() {
        XCTAssertEqual(classify(200), .answer)
        XCTAssertEqual(classify(204), .answer)
    }

    func testEveryDailyAllowanceIsRecognisedWhoeverRanOutOfIt() {
        for code in ["device_daily_limit_reached", "ip_daily_limit_reached", "global_daily_limit_reached"] {
            guard case .quotaReached = classify(429, code) else {
                return XCTFail("\(code) must read as a spent allowance")
            }
        }
    }

    func testAnUpstreamRateLimitIsBusyNotSpent() {
        XCTAssertEqual(classify(429, "upstream_rate_limited"), .busy)
        XCTAssertEqual(classify(429), .busy)
        XCTAssertEqual(classify(429, "something_new"), .busy)
    }

    func testASpentAllowanceResumesAtTheNextUTCMidnightWithoutAHeader() {
        XCTAssertEqual(
            classify(429, "ip_daily_limit_reached"),
            .quotaReached(resetsAt: EnrichmentPolicy.nextQuotaReset(after: now))
        )
    }

    func testTheProxysRetryAfterBeatsTheLocalCalendar() {
        XCTAssertEqual(
            classify(429, "device_daily_limit_reached", retryAfter: 600),
            .quotaReached(resetsAt: now.addingTimeInterval(600))
        )
    }

    func testAnAbsurdRetryAfterIsBounded() {
        XCTAssertEqual(
            classify(429, "device_daily_limit_reached", retryAfter: 9_999_999),
            .quotaReached(resetsAt: now.addingTimeInterval(25 * 3600))
        )
    }

    func testAnUnusableRetryAfterFallsBackToTheCalendar() {
        let calendarReset = EnrichmentPolicy.nextQuotaReset(after: now)
        for bad in [0.0, -5.0, .nan, .infinity] {
            XCTAssertEqual(
                classify(429, "device_daily_limit_reached", retryAfter: bad),
                .quotaReached(resetsAt: calendarReset),
                "Retry-After \(bad)"
            )
        }
    }

    func testOversizedRequestsAreTheirOwnVerdict() {
        XCTAssertEqual(classify(413), .payloadTooLarge)
    }

    func testEveryOtherErrorMeansTheServiceIsUnavailable() {
        for status in [400, 401, 403, 404, 500, 502, 503, 504, 529] {
            XCTAssertEqual(classify(status, "upstream_error"), .unavailable, "HTTP \(status)")
        }
    }

    func testTheLimitCodeMustSayDailyToBeTreatedAsSpent() {
        XCTAssertEqual(classify(500, "ip_daily_limit_reached"), .unavailable)
    }
}
