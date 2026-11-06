import XCTest
@testable import FlaccyCore

final class AccentChoiceTests: XCTestCase {

    private func luminance(_ rgb: UInt32) -> Double {
        func channel(_ shift: UInt32) -> Double {
            let value = Double((rgb >> shift) & 0xFF) / 255
            return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
    }

    private func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let (high, low) = (max(luminance(a), luminance(b)), min(luminance(a), luminance(b)))
        return (high + 0.05) / (low + 0.05)
    }

    func testBlueIsTheDefaultForMissingAndUnknownIDs() {
        XCTAssertEqual(AccentChoice(id: nil), .blue)
        XCTAssertEqual(AccentChoice(id: ""), .blue)
        XCTAssertEqual(AccentChoice(id: "adaptive"), .blue)
        XCTAssertEqual(AccentChoice(id: "ultraviolet"), .blue)
    }

    func testEveryChoiceRoundTripsThroughItsID() {
        for choice in AccentChoice.allCases {
            XCTAssertEqual(AccentChoice(id: choice.rawValue), choice)
        }
    }

    func testTheIDsAreTheLinuxThemeIDs() {
        XCTAssertEqual(
            AccentChoice.allCases.map(\.rawValue),
            ["blue", "rosewater", "aurora", "nocturne", "verdant", "sunset", "mono"]
        )
    }

    func testBlueIsTheSystemBlue() {
        XCTAssertEqual(AccentChoice.blue.light, 0x007AFF)
        XCTAssertEqual(AccentChoice.blue.dark, 0x0A84FF)
    }

    func testLightAccentsReadOnWhite() {
        for choice in AccentChoice.allCases {
            XCTAssertGreaterThanOrEqual(contrast(choice.light, 0xFFFFFF), 4.0, "\(choice)")
        }
    }

    func testDarkAccentsReadOnTheDarkBackgroundAndUnderAWhiteLabel() {
        for choice in AccentChoice.allCases {
            XCTAssertGreaterThanOrEqual(contrast(choice.dark, 0x1C1C1E), 4.5, "\(choice)")
            XCTAssertGreaterThanOrEqual(contrast(choice.dark, 0xFFFFFF), 3.0, "\(choice)")
        }
    }

    func testNoTwoAccentsShareAColor() {
        XCTAssertEqual(Set(AccentChoice.allCases.map(\.light)).count, AccentChoice.allCases.count)
        XCTAssertEqual(Set(AccentChoice.allCases.map(\.dark)).count, AccentChoice.allCases.count)
    }
}
