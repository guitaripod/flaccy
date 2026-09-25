import XCTest
@testable import flaccy

/// `ReviewPrompt.isEligible` is a pure function of the stored counters and ask
/// history, so the whole policy — first ask at the 2nd success, the 14-day
/// and 3-success cooldown on every ask after that, and the 3-per-365-day cap
/// — is pinned here without touching UserDefaults or the StoreKit sheet.
final class ReviewPromptTests: XCTestCase {

    private let day: TimeInterval = 86_400
    private let now = Date()

    private func daysAgo(_ days: Double) -> Date {
        now.addingTimeInterval(-days * day)
    }

    func testNoAskAtOneSuccess() {
        XCTAssertFalse(ReviewPrompt.isEligible(
            successCount: 1, askDates: [], successCountAtLastAsk: 0, now: now
        ))
    }

    func testAskAtTwoSuccesses() {
        XCTAssertTrue(ReviewPrompt.isEligible(
            successCount: 2, askDates: [], successCountAtLastAsk: 0, now: now
        ))
    }

    func testNoReAskBeforeFourteenDays() {
        XCTAssertFalse(ReviewPrompt.isEligible(
            successCount: 5, askDates: [daysAgo(13.9)], successCountAtLastAsk: 2, now: now
        ))
    }

    func testNoReAskBeforeThreeNewSuccesses() {
        XCTAssertFalse(ReviewPrompt.isEligible(
            successCount: 4, askDates: [daysAgo(30)], successCountAtLastAsk: 2, now: now
        ))
    }

    func testReAskAfterBothFourteenDaysAndThreeNewSuccesses() {
        XCTAssertTrue(ReviewPrompt.isEligible(
            successCount: 5, askDates: [daysAgo(14.1)], successCountAtLastAsk: 2, now: now
        ))
    }

    func testNeverAFourthAskWithinThreeSixtyFiveDays() {
        let askDates = [daysAgo(300), daysAgo(200), daysAgo(20)]
        XCTAssertFalse(ReviewPrompt.isEligible(
            successCount: 50, askDates: askDates, successCountAtLastAsk: 10, now: now
        ))
    }

    func testFourthAskAllowedOnceTheOldestAskAgesOut() {
        let askDates = [daysAgo(370), daysAgo(200), daysAgo(20)]
        XCTAssertTrue(ReviewPrompt.isEligible(
            successCount: 50, askDates: askDates, successCountAtLastAsk: 10, now: now
        ))
    }

    func testAgedOutAskStillStartsItsOwnFourteenDayThreeSuccessCooldown() {
        let askDates = [daysAgo(370), daysAgo(200), daysAgo(5)]
        XCTAssertFalse(ReviewPrompt.isEligible(
            successCount: 50, askDates: askDates, successCountAtLastAsk: 10, now: now
        ))
    }
}
