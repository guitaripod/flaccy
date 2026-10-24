import XCTest
@testable import FlaccyCore

final class ArtworkTintTests: XCTestCase {

    private func swatch(_ pixels: [(UInt8, UInt8, UInt8)]) -> [UInt8] {
        pixels.flatMap { [$0.0, $0.1, $0.2, 255] }
    }

    private func solid(_ red: UInt8, _ green: UInt8, _ blue: UInt8) -> [UInt8] {
        swatch(Array(repeating: (red, green, blue), count: 256))
    }

    func testRedCoverReadsAsRed() throws {
        let tint = try XCTUnwrap(ArtworkTint.dominant(inRGBA: solid(220, 20, 20)))
        XCTAssertEqual(tint.hue, 0, accuracy: 0.03)
        XCTAssertGreaterThanOrEqual(tint.saturation, 0.35)
    }

    func testBlueCoverReadsAsBlue() throws {
        let tint = try XCTUnwrap(ArtworkTint.dominant(inRGBA: solid(30, 60, 230)))
        XCTAssertEqual(tint.hue, 0.64, accuracy: 0.05)
    }

    func testGreyCoverHasNoSaturation() throws {
        let tint = try XCTUnwrap(ArtworkTint.dominant(inRGBA: solid(128, 128, 128)))
        XCTAssertEqual(tint.saturation, 0)
    }

    func testBlackCoverHasNoTint() {
        XCTAssertNil(ArtworkTint.dominant(inRGBA: solid(0, 0, 0)))
        XCTAssertNil(ArtworkTint.dominant(inRGBA: []))
    }

    func testMostlyGreyCoverWithARedObjectReadsRed() throws {
        let grey = Array(repeating: (UInt8(120), UInt8(120), UInt8(120)), count: 220)
        let red = Array(repeating: (UInt8(230), UInt8(30), UInt8(30)), count: 36)
        let tint = try XCTUnwrap(ArtworkTint.dominant(inRGBA: swatch(grey + red)))
        XCTAssertEqual(tint.hue, 0, accuracy: 0.03)
    }

    func testTheLargerVividAreaWins() throws {
        let green = Array(repeating: (UInt8(30), UInt8(200), UInt8(60)), count: 180)
        let blue = Array(repeating: (UInt8(30), UInt8(60), UInt8(220)), count: 76)
        let tint = try XCTUnwrap(ArtworkTint.dominant(inRGBA: swatch(green + blue)))
        XCTAssertEqual(tint.hue, 0.36, accuracy: 0.05)
    }

    func testSaturationIsClampedForAWashThatStaysReadable() throws {
        let tint = try XCTUnwrap(ArtworkTint.dominant(inRGBA: solid(255, 0, 0)))
        XCTAssertLessThanOrEqual(tint.saturation, 0.85)
        let pale = try XCTUnwrap(ArtworkTint.dominant(inRGBA: solid(200, 170, 170)))
        XCTAssertGreaterThanOrEqual(pale.saturation, 0.35)
    }
}
