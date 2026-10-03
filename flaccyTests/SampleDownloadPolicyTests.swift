import XCTest
@testable import flaccy

/// The 130 MB sample album starts by itself only on an unmetered, unconstrained
/// route; everything else asks first, and Low Data Mode outranks cellular
/// because it is the system telling apps to hold back.
final class SampleDownloadPolicyTests: XCTestCase {

    func testUnmeteredRouteDownloadsWithoutAsking() {
        XCTAssertNil(SampleDownloadPolicy.confirmation(isExpensive: false, isConstrained: false))
    }

    func testCellularAsksFirst() {
        XCTAssertEqual(SampleDownloadPolicy.confirmation(isExpensive: true, isConstrained: false), .cellular)
    }

    func testLowDataModeAsksFirst() {
        XCTAssertEqual(SampleDownloadPolicy.confirmation(isExpensive: false, isConstrained: true), .lowDataMode)
    }

    func testLowDataModeOutranksCellular() {
        XCTAssertEqual(SampleDownloadPolicy.confirmation(isExpensive: true, isConstrained: true), .lowDataMode)
    }
}
