import XCTest
@testable import FlaccyCore

final class RemoteFetchRetryTests: XCTestCase {

    func testEachFailureWaitsLongerUntilTheSongIsGivenUp() {
        XCTAssertEqual((1...7).map { RemoteFetchRetry.delay(afterFailures: $0) }, [0.5, 1, 2, 4, 8, 8, 8])
        XCTAssertNil(RemoteFetchRetry.delay(afterFailures: 8))
        XCTAssertNil(RemoteFetchRetry.delay(afterFailures: 0))
        XCTAssertEqual(RemoteFetchRetry.delays.reduce(0, +), 31.5)
    }

    func testOnlyFailuresThatCanPassAreTriedAgain() {
        for status in [408, 425, 429, 500, 502, 503, 504, 599] {
            XCTAssertTrue(RemoteFetchRetry.isTransient(httpStatus: status), "\(status)")
        }
        for status in [200, 206, 400, 401, 403, 404, 416, 600] {
            XCTAssertFalse(RemoteFetchRetry.isTransient(httpStatus: status), "\(status)")
        }
    }

    func testAFailedPreloadWaitsLongerEachTime() {
        XCTAssertEqual((0...3).map(RemoteFetchRetry.preloadDelay(attempt:)), [2, 2, 4, 6])
        XCTAssertEqual(RemoteFetchRetry.itemRecoveries, 3)
    }
}
