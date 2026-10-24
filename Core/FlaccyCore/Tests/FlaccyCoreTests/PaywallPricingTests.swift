import XCTest
@testable import FlaccyCore

final class PaywallPricingTests: XCTestCase {

    func testRoundsTheRatioUp() {
        XCTAssertEqual(PaywallPricing.yearsOfYearly(lifetime: 24.99, yearly: 7.99), 4)
        XCTAssertEqual(PaywallPricing.yearsOfYearly(lifetime: 19.99, yearly: 7.99), 3)
    }

    func testExactMultiplesAreNotRoundedUp() {
        XCTAssertEqual(PaywallPricing.yearsOfYearly(lifetime: 15.98, yearly: 7.99), 2)
        XCTAssertEqual(PaywallPricing.yearsOfYearly(lifetime: 30, yearly: 10), 3)
    }

    func testSamePriceIsNotWorthSaying() {
        XCTAssertNil(PaywallPricing.yearsOfYearly(lifetime: 7.99, yearly: 7.99))
    }

    func testCheaperThanYearlyIsNotWorthSaying() {
        XCTAssertNil(PaywallPricing.yearsOfYearly(lifetime: 5, yearly: 7.99))
    }

    func testNoYearlyPriceGivesNothing() {
        XCTAssertNil(PaywallPricing.yearsOfYearly(lifetime: 24.99, yearly: 0))
        XCTAssertNil(PaywallPricing.yearsOfYearly(lifetime: 24.99, yearly: -1))
    }
}
