import XCTest
@testable import FlaccyCore

/// Mirrored by `linux/shared/src/equalizer/spectrum.rs`.
final class SpectrumAnalyzerTests: XCTestCase {

    private let rate = 48_000.0

    private func bins(forSineAt frequency: Double, amplitude: Double) -> [Float] {
        let analyzer = SpectrumAnalyzer(sampleRate: rate)
        let samples = (0..<SpectrumAnalyzer.windowSize).map { Float(amplitude * sin(2 * Double.pi * frequency * Double($0) / rate)) }
        return samples.withUnsafeBufferPointer { analyzer.analyze($0.baseAddress!) }
    }

    private func expectedBin(for frequency: Double) -> Int {
        Int((Double(SpectrumAnalyzer.binCount) * log(frequency / 20) / log(1_000)).rounded(.down))
    }

    func testSilenceReadsTheFloor() {
        let analyzer = SpectrumAnalyzer(sampleRate: rate)
        let silence = [Float](repeating: 0, count: SpectrumAnalyzer.windowSize)

        let bins = silence.withUnsafeBufferPointer { analyzer.analyze($0.baseAddress!) }

        XCTAssertEqual(bins.count, SpectrumAnalyzer.binCount)
        XCTAssertTrue(bins.allSatisfy { $0 == SpectrumAnalyzer.floorDecibels })
    }

    func testASineReadsItsOwnLevelAtItsOwnFrequency() {
        let frequency = 43.0 * rate / Double(SpectrumAnalyzer.windowSize)

        let result = bins(forSineAt: frequency, amplitude: 0.5)

        let peak = result.max() ?? 0
        XCTAssertEqual(peak, -6.02, accuracy: 0.3)
        let index = result.firstIndex(of: peak) ?? -1
        XCTAssertEqual(index, expectedBin(for: frequency), accuracy: 1)
    }

    func testTheLoudestBinFollowsTheFrequency() {
        var previous = -1
        for frequency in [100.0, 440.0, 2_000.0, 9_000.0] {
            let result = bins(forSineAt: frequency, amplitude: 0.5)
            let index = result.firstIndex(of: result.max() ?? 0) ?? -1
            XCTAssertGreaterThan(index, previous)
            XCTAssertEqual(index, expectedBin(for: frequency), accuracy: 2, "\(frequency) Hz")
            previous = index
        }
    }

    func testAQuieterSineReadsQuieter() {
        let loud = bins(forSineAt: 1_007.8, amplitude: 0.5).max() ?? 0
        let quiet = bins(forSineAt: 1_007.8, amplitude: 0.05).max() ?? 0

        XCTAssertEqual(loud - quiet, 20, accuracy: 0.5)
    }
}
