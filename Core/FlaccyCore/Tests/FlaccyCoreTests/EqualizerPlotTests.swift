import XCTest
@testable import FlaccyCore

/// Mirrored by `linux/shared/src/equalizer/plot.rs`.
final class EqualizerPlotTests: XCTestCase {

    func testTheAxisRunsFromTwentyHertzToTwentyKilohertz() {
        XCTAssertEqual(EqualizerPlot.x(forFrequency: 20, width: 800), 0, accuracy: 1e-9)
        XCTAssertEqual(EqualizerPlot.x(forFrequency: 20_000, width: 800), 800, accuracy: 1e-9)
        XCTAssertEqual(EqualizerPlot.x(forFrequency: 632.455_532, width: 800), 400, accuracy: 1e-3)
    }

    func testFrequencyAndPositionRoundTrip() {
        for frequency in [20.0, 64, 440, 1_000, 8_000, 20_000] {
            let x = EqualizerPlot.x(forFrequency: frequency, width: 612)
            XCTAssertEqual(EqualizerPlot.frequency(atX: x, width: 612), frequency, accuracy: frequency * 1e-9)
        }
    }

    func testAPositionOutsideThePlotIsClamped() {
        XCTAssertEqual(EqualizerPlot.frequency(atX: -50, width: 300), 20, accuracy: 1e-9)
        XCTAssertEqual(EqualizerPlot.frequency(atX: 900, width: 300), 20_000, accuracy: 1e-6)
    }

    func testTheVerticalAxisRunsPlusToMinusTwelve() {
        XCTAssertEqual(EqualizerPlot.y(forDecibels: 12, height: 200), 0, accuracy: 1e-9)
        XCTAssertEqual(EqualizerPlot.y(forDecibels: 0, height: 200), 100, accuracy: 1e-9)
        XCTAssertEqual(EqualizerPlot.y(forDecibels: -12, height: 200), 200, accuracy: 1e-9)
        XCTAssertEqual(EqualizerPlot.decibels(atY: 25, height: 200), 9, accuracy: 1e-9)
    }

    func testAGainSettlesOnHalfDecibelsWithAMagnetAtZero() {
        XCTAssertEqual(EqualizerPlot.snappedGain(0.3), 0)
        XCTAssertEqual(EqualizerPlot.snappedGain(-0.39), 0)
        XCTAssertEqual(EqualizerPlot.snappedGain(0.6), 0.5)
        XCTAssertEqual(EqualizerPlot.snappedGain(3.8), 4)
        XCTAssertEqual(EqualizerPlot.snappedGain(-7.2), -7)
        XCTAssertEqual(EqualizerPlot.snappedGain(40), 12)
        XCTAssertEqual(EqualizerPlot.snappedGain(-40), -12)
    }

    func testAParametricGainSettlesOnTenthsOfADecibel() {
        XCTAssertEqual(EqualizerPlot.preciseGain(0.2), 0)
        XCTAssertEqual(EqualizerPlot.preciseGain(2.34), 2.3)
        XCTAssertEqual(EqualizerPlot.preciseGain(-11.96), -12)
    }

    func testATouchFindsTheColumnItIsIn() {
        let width = 600.0
        let positions = GraphicSolver.centres.map { EqualizerPlot.x(forFrequency: $0, width: width) }
        for (index, x) in positions.enumerated() {
            XCTAssertEqual(EqualizerPlot.nearestCentreIndex(atX: x + 3, width: width), index)
        }
        XCTAssertEqual(EqualizerPlot.nearestCentreIndex(atX: -20, width: width), 0)
        XCTAssertEqual(EqualizerPlot.nearestCentreIndex(atX: 900, width: width), 9)
    }

    func testAFrequencyKeepsThreeSignificantFigures() {
        XCTAssertEqual(EqualizerPlot.roundedFrequency(1_003.7), 1_000, accuracy: 1e-9)
        XCTAssertEqual(EqualizerPlot.roundedFrequency(47.34), 47.3, accuracy: 1e-9)
        XCTAssertEqual(EqualizerPlot.roundedFrequency(12_345), 12_300, accuracy: 1e-9)
        XCTAssertEqual(EqualizerPlot.roundedFrequency(5), 20, accuracy: 1e-9)
        XCTAssertEqual(EqualizerPlot.roundedFrequency(40_000), 20_000, accuracy: 1e-9)
    }
}
