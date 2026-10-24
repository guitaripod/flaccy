import XCTest
@testable import FlaccyCore

/// Mirrored by the tests in `linux/shared/src/equalizer/`: the same golden
/// coefficients, the same solver and headroom numbers, the same preset table.
final class EqualizerMathTests: XCTestCase {

    private func assertCoefficients(
        _ c: BiquadCoefficients,
        _ expected: [Double],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let actual = [c.b0, c.b1, c.b2, c.a1, c.a2]
        for (a, e) in zip(actual, expected) {
            XCTAssertEqual(a, e, accuracy: 1e-12, file: file, line: line)
        }
    }

    func testBellMatchesTheCookbook() {
        let c = BiquadMath.coefficients(type: .bell, frequency: 1_000, gain: 6, q: 1.41, sampleRate: 48_000)
        assertCoefficients(c, [1.031577910616767, -1.919976143597597, 0.904965631438766, -1.919976143597597, 0.936543542055534])
    }

    func testLowShelfMatchesTheCookbook() {
        let c = BiquadMath.coefficients(type: .lowShelf, frequency: 200, gain: -4, q: 0.71, sampleRate: 44_100)
        assertCoefficients(c, [0.995379761918072, -1.955153384139738, 0.960404321312953, -1.954968938337245, 0.955968529033518])
    }

    func testHighShelfMatchesTheCookbook() {
        let c = BiquadMath.coefficients(type: .highShelf, frequency: 6_000, gain: 3, q: 0.71, sampleRate: 96_000)
        assertCoefficients(c, [1.347599661698509, -2.019319747293779, 0.810799478426938, -1.409259540929382, 0.548338933761050])
    }

    func testHighPassMatchesTheCookbook() {
        let c = BiquadMath.coefficients(type: .highPass, frequency: 80, gain: 0, q: 0.71, sampleRate: 48_000)
        assertCoefficients(c, [0.992652274596786, -1.985304549193571, 0.992652274596786, -1.985250119947334, 0.985358978439808])
    }

    func testLowPassMatchesTheCookbook() {
        let c = BiquadMath.coefficients(type: .lowPass, frequency: 12_000, gain: 0, q: 0.71, sampleRate: 48_000)
        assertCoefficients(c, [0.293388429752066, 0.586776859504132, 0.293388429752066, 0.0, 0.173553719008264])
    }

    func testABellReachesItsGainAtItsCentre() {
        let c = BiquadMath.coefficients(type: .bell, frequency: 1_000, gain: 6, q: 1.41, sampleRate: 48_000)
        XCTAssertEqual(BiquadMath.magnitudeDecibels(c, frequency: 1_000, sampleRate: 48_000), 6, accuracy: 0.001)
    }

    func testShelvesSettleAtTheirGainOnTheirOwnSide() {
        let low = BiquadMath.coefficients(type: .lowShelf, frequency: 200, gain: 6, q: 0.71, sampleRate: 48_000)
        XCTAssertEqual(BiquadMath.magnitudeDecibels(low, frequency: 20, sampleRate: 48_000), 6, accuracy: 0.05)
        XCTAssertEqual(BiquadMath.magnitudeDecibels(low, frequency: 20_000, sampleRate: 48_000), 0, accuracy: 0.05)
        let high = BiquadMath.coefficients(type: .highShelf, frequency: 4_000, gain: 6, q: 0.71, sampleRate: 48_000)
        XCTAssertEqual(BiquadMath.magnitudeDecibels(high, frequency: 20_000, sampleRate: 48_000), 6, accuracy: 0.2)
    }

    func testAPassFilterIsThreeDecibelsDownAtItsCornerWhenQIsMaximallyFlat() {
        let c = BiquadMath.coefficients(type: .highPass, frequency: 100, gain: 0, q: 0.7071, sampleRate: 48_000)
        XCTAssertEqual(BiquadMath.magnitudeDecibels(c, frequency: 100, sampleRate: 48_000), -3.01, accuracy: 0.02)
    }

    func testEveryPresetIsMetExactlyAtTheCentres() {
        for preset in EqualizerPresets.all {
            let bands = preset.resolvedBands()
            for (centre, target) in zip(GraphicSolver.centres, preset.targets) {
                let heard = BiquadMath.responseDecibels(bands, frequency: centre)
                XCTAssertEqual(heard, target, accuracy: 0.01, "\(preset.name) at \(centre) Hz")
            }
        }
    }

    func testNoSolvedFilterAsksForAnUnreasonableBoost() {
        for preset in EqualizerPresets.all {
            let worst = preset.resolvedBands().map { abs($0.gain) }.max() ?? 0
            XCTAssertLessThan(worst, 8, preset.name)
        }
    }

    func testAnAlternatingCurveStaysWithinTheFilterLimit() {
        let zigzag: [Double] = [12, -12, 12, -12, 12, -12, 12, -12, 12, -12]
        let worst = GraphicSolver.bands(forTargets: zigzag).map { abs($0.gain) }.max() ?? 0
        XCTAssertLessThanOrEqual(worst, GraphicSolver.filterGainLimit)
    }

    func testFlatSolvesToNothing() {
        XCTAssertTrue(GraphicSolver.solve(targets: Array(repeating: 0, count: 10)).allSatisfy { abs($0) < 1e-9 })
        XCTAssertTrue(EqualizerPresets.flat.isFlat)
    }

    func testAutoPreampTurnsDownByThePeakOfTheSummedCurve() {
        XCTAssertEqual(EqualizerPresets.profile(forKey: "bassBoost")!.preamp(), -6.1, accuracy: 1e-9)
        XCTAssertEqual(EqualizerPresets.profile(forKey: "rock")!.preamp(), -4.1, accuracy: 1e-9)
        XCTAssertEqual(EqualizerPresets.profile(forKey: "electronic")!.preamp(), -5.1, accuracy: 1e-9)
    }

    func testACurveThatOnlyCutsIsNotTurnedDown() {
        for key in ["bassReducer", "trebleReducer", "soften"] {
            XCTAssertEqual(EqualizerPresets.profile(forKey: key)!.preamp(), 0, key)
        }
    }

    func testAutoPreampNeverLetsAnyFrequencyExceedZero() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<40 {
            let count = Int.random(in: 1...6, using: &generator)
            let bands = (0..<count).map { _ in
                EqualizerBand(
                    type: [.bell, .lowShelf, .highShelf].randomElement(using: &generator)!,
                    frequency: Double.random(in: 40...16_000, using: &generator),
                    gain: Double.random(in: -12...12, using: &generator),
                    q: Double.random(in: 0.4...6, using: &generator)
                )
            }
            let preamp = Headroom.autoPreamp(for: bands)
            for f in BiquadMath.logFrequencies(count: 600) {
                XCTAssertLessThanOrEqual(BiquadMath.responseDecibels(bands, frequency: f) + preamp, 0.06)
            }
        }
    }

    func testThePresetTableIsPinned() {
        XCTAssertEqual(EqualizerPresets.entries.count, 16)
        XCTAssertEqual(EqualizerPresets.entries.map(\.key), [
            "flat", "bassBoost", "bassReducer", "trebleBoost", "trebleReducer", "vocal", "spokenWord", "soften",
            "loudness", "acoustic", "classical", "rock", "electronic", "hipHop", "jazz", "pop",
        ])
        XCTAssertEqual(EqualizerPresets.profile(forKey: "rock")?.targets, [4, 3, 1, 0, -1, 0, 2, 3, 4, 4])
        XCTAssertEqual(EqualizerPresets.profile(forKey: "hipHop")?.targets, [6, 5, 2, 1, -1, -1, 1, 0, 1, 2])
        XCTAssertEqual(EqualizerPresets.tuneKeys.count + EqualizerPresets.genreKeys.count + 1, 16)
    }
}
