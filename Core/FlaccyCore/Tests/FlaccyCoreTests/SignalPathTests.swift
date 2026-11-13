import XCTest
@testable import FlaccyCore

final class SignalPathTests: XCTestCase {

    func testNothingPlayingIsIdle() {
        XCTAssertEqual(SignalPathVerdict.of(sourceIsLossless: nil, processed: true, output: .bluetooth), .idle)
    }

    func testBluetoothLeadsWhateverFlaccyDoes() {
        XCTAssertEqual(SignalPathVerdict.of(sourceIsLossless: true, processed: false, output: .bluetooth), .reencodedForBluetooth)
        XCTAssertEqual(SignalPathVerdict.of(sourceIsLossless: false, processed: true, output: .bluetooth), .reencodedForBluetooth)
    }

    func testProcessingComesBeforeTheFileFormat() {
        XCTAssertEqual(SignalPathVerdict.of(sourceIsLossless: false, processed: true, output: .headphones), .shaped)
        XCTAssertEqual(SignalPathVerdict.of(sourceIsLossless: true, processed: true, output: .usb), .shaped)
    }

    func testAnUnprocessedFileIsUntouchedOrLossy() {
        XCTAssertEqual(SignalPathVerdict.of(sourceIsLossless: true, processed: false, output: .usb), .untouched)
        XCTAssertEqual(SignalPathVerdict.of(sourceIsLossless: true, processed: false, output: nil), .untouched)
        XCTAssertEqual(SignalPathVerdict.of(sourceIsLossless: false, processed: false, output: .speaker), .lossySource)
    }

    func testEveryOutputPointsAtGuideCardsThatExist() {
        for output in SignalOutputKind.allCases {
            let cards = SignalPathVerdict.guideCards(for: output)
            XCTAssertFalse(cards.isEmpty)
            XCTAssertTrue(cards.allSatisfy { (0..<6).contains($0) })
        }
        XCTAssertEqual(SignalPathVerdict.guideCards(for: .bluetooth), [0, 1, 2])
    }
}
