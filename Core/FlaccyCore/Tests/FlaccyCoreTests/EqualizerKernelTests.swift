import XCTest
@testable import FlaccyCore

/// Mirrored by `linux/shared/src/equalizer/kernel.rs`: the same golden impulse
/// response, the same crossfade and guard behaviour.
final class EqualizerKernelTests: XCTestCase {

    private let rate = 48_000.0

    private func run(
        _ kernel: EqualizerKernel,
        planar input: [[Float]],
        chunk: Int = 512
    ) -> [[Float]] {
        var output = input
        let channels = input.count
        let frames = input[0].count
        let planes = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: channels)
        defer { planes.deallocate() }
        var start = 0
        while start < frames {
            let count = min(chunk, frames - start)
            var pointers: [UnsafeMutablePointer<Float>] = []
            for channel in 0..<channels {
                output[channel].withUnsafeMutableBufferPointer { buffer in
                    pointers.append(buffer.baseAddress! + start)
                }
            }
            for channel in 0..<channels { planes[channel] = pointers[channel] }
            kernel.process(planes: planes, planeStride: 1, frames: count)
            start += count
        }
        return output
    }

    private func settle(_ kernel: EqualizerKernel, channels: Int = 1) {
        _ = run(kernel, planar: Array(repeating: [Float](repeating: 0, count: 3_000), count: channels))
    }

    private func impulse(length: Int) -> [[Float]] {
        var samples = [Float](repeating: 0, count: length)
        samples[0] = 1
        return [samples]
    }

    func testTheImpulseResponseMatchesTheGoldenVector() {
        let kernel = EqualizerKernel(channelCount: 1, sampleRate: rate)
        kernel.configure(
            bands: [EqualizerBand(type: .bell, frequency: 1_000, gain: 6, q: 1.41)],
            preampDecibels: -2,
            isEngaged: true,
            peakGuard: false
        )
        settle(kernel)

        let response = run(kernel, planar: impulse(length: 64))[0]

        let golden: [Float] = [0.819411461, 0.048159196, 0.043889747, 0.039164084, 0.034089448, 0.028772056, 0.023315410, 0.017818747]
        for (index, expected) in golden.enumerated() {
            XCTAssertEqual(response[index], expected, accuracy: 1e-6, "sample \(index)")
        }
    }

    func testTheImpulseResponseMatchesADoublePrecisionReference() {
        let bands = [
            EqualizerBand(type: .bell, frequency: 1_000, gain: 6, q: 1.41),
            EqualizerBand(type: .lowShelf, frequency: 120, gain: -3, q: 0.71),
            EqualizerBand(type: .highShelf, frequency: 9_000, gain: 4, q: 0.71),
        ]
        let kernel = EqualizerKernel(channelCount: 1, sampleRate: rate)
        kernel.configure(bands: bands, preampDecibels: -3, isEngaged: true, peakGuard: false)
        settle(kernel)

        let response = run(kernel, planar: impulse(length: 2_048))[0]

        let gain = pow(10, -3.0 / 20)
        let coefficients = bands.map { BiquadMath.coefficients(for: $0, sampleRate: rate) }
        var z = [(Double, Double)](repeating: (0, 0), count: bands.count)
        for n in 0..<response.count {
            var value = (n == 0 ? 1.0 : 0.0) * gain
            for s in 0..<coefficients.count {
                let c = coefficients[s]
                let out = c.b0 * value + z[s].0
                z[s].0 = c.b1 * value - c.a1 * out + z[s].1
                z[s].1 = c.b2 * value - c.a2 * out
                value = out
            }
            XCTAssertEqual(Double(response[n]), value, accuracy: 2e-5, "sample \(n)")
        }
    }

    func testTheKernelsFrequencyResponseIsTheCurveThatIsDrawn() {
        let profile = EqualizerPresets.profile(forKey: "rock")!
        let bands = profile.resolvedBands()
        let kernel = EqualizerKernel(channelCount: 1, sampleRate: rate)
        kernel.configure(bands: bands, preampDecibels: 0, isEngaged: true, peakGuard: false)
        settle(kernel)

        let response = run(kernel, planar: impulse(length: 16_384))[0]

        for frequency in [60.0, 250.0, 1_000.0, 4_000.0, 12_000.0] {
            var re = 0.0
            var im = 0.0
            for (n, sample) in response.enumerated() {
                let phase = 2 * Double.pi * frequency * Double(n) / rate
                re += Double(sample) * cos(phase)
                im -= Double(sample) * sin(phase)
            }
            let heard = 20 * log10((re * re + im * im).squareRoot())
            XCTAssertEqual(heard, BiquadMath.responseDecibels(bands, frequency: frequency), accuracy: 0.05, "\(frequency) Hz")
        }
    }

    func testABypassedStageLeavesEverySampleBitExact() {
        let kernel = EqualizerKernel(channelCount: 2, sampleRate: rate)
        kernel.configure(bands: EqualizerPresets.profile(forKey: "rock")!.resolvedBands(), preampDecibels: -4, isEngaged: false, peakGuard: true)
        var generator = SystemRandomNumberGenerator()
        let input = (0..<2).map { _ in (0..<4_096).map { _ in Float.random(in: -1...1, using: &generator) } }

        let output = run(kernel, planar: input)

        XCTAssertEqual(output, input)
        XCTAssertTrue(kernel.isBypassed)
    }

    func testEngagingStartsFromTheDrySignalSoNothingClicks() {
        let kernel = EqualizerKernel(channelCount: 1, sampleRate: rate)
        kernel.configure(bands: [EqualizerBand(type: .bell, frequency: 500, gain: 9, q: 1)], preampDecibels: -9, isEngaged: true, peakGuard: false)
        let tone = (0..<4_096).map { Float(0.5 * sin(2 * Double.pi * 440 * Double($0) / rate)) }

        let output = run(kernel, planar: [tone])[0]

        XCTAssertEqual(output[0], tone[0])
        var largestStep: Float = 0
        for n in 1..<output.count { largestStep = max(largestStep, abs(output[n] - output[n - 1])) }
        XCTAssertLessThan(largestStep, 0.1)
    }

    func testDisengagingCrossfadesOutAndThenPassesAudioThroughUntouched() {
        let kernel = EqualizerKernel(channelCount: 1, sampleRate: rate)
        kernel.configure(bands: [EqualizerBand(type: .bell, frequency: 500, gain: 9, q: 1)], preampDecibels: -9, isEngaged: true, peakGuard: false)
        settle(kernel)

        kernel.configure(bands: [], preampDecibels: 0, isEngaged: false, peakGuard: false)
        let tone = (0..<8_192).map { Float(0.4 * sin(2 * Double.pi * 330 * Double($0) / rate)) }
        let output = run(kernel, planar: [tone])[0]

        XCTAssertTrue(kernel.isBypassed)
        XCTAssertEqual(Array(output[4_096...]), Array(tone[4_096...]))
    }

    func testThePeakGuardHoldsTheCeiling() {
        let kernel = EqualizerKernel(channelCount: 2, sampleRate: rate)
        kernel.configure(bands: [], preampDecibels: 6, isEngaged: true, peakGuard: true)
        let tone = (0..<8_192).map { Float(0.95 * sin(2 * Double.pi * 220 * Double($0) / rate)) }
        settle(kernel, channels: 2)

        let output = run(kernel, planar: [tone, tone])

        let peak = output.flatMap { $0 }.map { abs($0) }.max() ?? 0
        XCTAssertLessThanOrEqual(peak, EqualizerKernel.guardCeiling + 1e-5)
        XCTAssertTrue(kernel.guardReduced)
    }

    func testWithoutTheGuardABoostCanExceedFullScale() {
        let kernel = EqualizerKernel(channelCount: 1, sampleRate: rate)
        kernel.configure(bands: [], preampDecibels: 6, isEngaged: true, peakGuard: false)
        settle(kernel)
        let tone = (0..<4_096).map { Float(0.9 * sin(2 * Double.pi * 220 * Double($0) / rate)) }

        let output = run(kernel, planar: [tone])[0]

        XCTAssertGreaterThan(output.map { abs($0) }.max() ?? 0, 1)
    }

    func testChangingTheCurveWhilePlayingNeverJumps() {
        let kernel = EqualizerKernel(channelCount: 1, sampleRate: rate)
        kernel.configure(bands: [EqualizerBand(type: .bell, frequency: 200, gain: 8, q: 1)], preampDecibels: 0, isEngaged: true, peakGuard: false)
        settle(kernel)
        let tone = (0..<6_144).map { Float(0.4 * sin(2 * Double.pi * 100 * Double($0) / rate)) }

        let first = run(kernel, planar: [Array(tone[0..<3_072])])[0]
        kernel.configure(bands: [EqualizerBand(type: .bell, frequency: 300, gain: -8, q: 2)], preampDecibels: 0, isEngaged: true, peakGuard: false)
        let second = run(kernel, planar: [Array(tone[3_072...])])[0]

        let stream = first + second
        var largestStep: Float = 0
        for n in 1..<stream.count { largestStep = max(largestStep, abs(stream[n] - stream[n - 1])) }
        XCTAssertLessThan(largestStep, 0.03)
    }

    func testChannelsAreProcessedIndependently() {
        let kernel = EqualizerKernel(channelCount: 2, sampleRate: rate)
        kernel.configure(bands: [EqualizerBand(type: .bell, frequency: 1_000, gain: 6, q: 1.41)], preampDecibels: -6, isEngaged: true, peakGuard: false)
        settle(kernel, channels: 2)
        var left = [Float](repeating: 0, count: 64)
        left[0] = 1
        let right = [Float](repeating: 0, count: 64)

        let output = run(kernel, planar: [left, right])

        XCTAssertGreaterThan(abs(output[0][0]), 0.1)
        XCTAssertTrue(output[1].allSatisfy { $0 == 0 })
    }

    func testInterleavedAndPlanarAudioComeOutTheSame() {
        let bands = EqualizerPresets.profile(forKey: "electronic")!.resolvedBands()
        let planarKernel = EqualizerKernel(channelCount: 2, sampleRate: rate)
        let interleavedKernel = EqualizerKernel(channelCount: 2, sampleRate: rate)
        for kernel in [planarKernel, interleavedKernel] {
            kernel.configure(bands: bands, preampDecibels: -5, isEngaged: true, peakGuard: true)
        }
        let left = (0..<3_000).map { Float(0.3 * sin(2 * Double.pi * 180 * Double($0) / rate)) }
        let right = (0..<3_000).map { Float(0.3 * sin(2 * Double.pi * 2_400 * Double($0) / rate)) }
        let planar = run(planarKernel, planar: [left, right])

        var interleaved = [Float](repeating: 0, count: 6_000)
        for n in 0..<3_000 {
            interleaved[n * 2] = left[n]
            interleaved[n * 2 + 1] = right[n]
        }
        interleaved.withUnsafeMutableBufferPointer { buffer in
            let planes = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 2)
            defer { planes.deallocate() }
            planes[0] = buffer.baseAddress!
            planes[1] = buffer.baseAddress! + 1
            interleavedKernel.process(planes: planes, planeStride: 2, frames: 3_000)
        }

        for n in 0..<3_000 {
            XCTAssertEqual(interleaved[n * 2], planar[0][n], accuracy: 1e-6)
            XCTAssertEqual(interleaved[n * 2 + 1], planar[1][n], accuracy: 1e-6)
        }
    }

    func testAKernelBornWithASongHasTheCurveInForceFromItsFirstSample() {
        let kernel = EqualizerKernel(channelCount: 1, sampleRate: rate)
        kernel.configure(bands: [], preampDecibels: -6, isEngaged: true, peakGuard: true, startsEngaged: true)
        let input = [[Float](repeating: 0.5, count: 64)]

        let output = run(kernel, planar: input)[0]

        let expected = Float(0.5 * pow(10, -6.0 / 20))
        XCTAssertEqual(output[0], expected, accuracy: 1e-6)
        XCTAssertEqual(output[63], expected, accuracy: 1e-6)
    }

    func testAKernelThatAppearsUnderAPlayingSongStillFadesIn() {
        let kernel = EqualizerKernel(channelCount: 1, sampleRate: rate)
        kernel.configure(bands: [], preampDecibels: -6, isEngaged: true, peakGuard: true)
        let output = run(kernel, planar: [[Float](repeating: 0.5, count: 64)])[0]

        XCTAssertEqual(output[0], 0.5, accuracy: 1e-3)
        XCTAssertLessThan(output[63], 0.5)
    }

    func testTheGuardLeavesAHotMasterAloneWhenNothingIsBoosted() {
        let kernel = EqualizerKernel(channelCount: 1, sampleRate: rate)
        kernel.configure(
            bands: [EqualizerBand(type: .bell, frequency: 60, gain: -2, q: 1.41)],
            preampDecibels: 0,
            isEngaged: true,
            peakGuard: true,
            startsEngaged: true
        )
        let tone = (0..<8_192).map { Float(0.99 * sin(2 * Double.pi * 3_000 * Double($0) / rate)) }

        let output = run(kernel, planar: [tone])[0]

        XCTAssertFalse(kernel.guardReduced)
        XCTAssertEqual(output.map { abs($0) }.max() ?? 0, 0.99, accuracy: 0.01)
    }

    func testDisengagingWhileTheGuardIsActingLeavesNoStepWhenItHandsOver() {
        let kernel = EqualizerKernel(channelCount: 1, sampleRate: rate)
        kernel.configure(bands: [], preampDecibels: 6, isEngaged: true, peakGuard: true, startsEngaged: true)
        let loud = [[Float](repeating: 0.8, count: 4_096)]
        _ = run(kernel, planar: loud)
        kernel.configure(bands: [], preampDecibels: 6, isEngaged: false, peakGuard: true)

        let output = run(kernel, planar: [[Float](repeating: 0.8, count: 12_000)], chunk: 256)[0]

        let gains = output.map { Double($0) / 0.8 }
        let largestStep = zip(gains, gains.dropFirst()).map { abs($1 - $0) }.max() ?? 0
        XCTAssertLessThan(largestStep, 0.002)
        XCTAssertEqual(output.last ?? 0, 0.8, accuracy: 1e-6)
        XCTAssertTrue(kernel.isBypassed)
    }

    func testABandThatIsNotANumberCannotPoisonTheAudio() {
        let kernel = EqualizerKernel(channelCount: 1, sampleRate: rate)
        kernel.configure(
            bands: [
                EqualizerBand(type: .bell, frequency: .nan, gain: 3, q: 1),
                EqualizerBand(type: .bell, frequency: 1_000, gain: .nan, q: 1),
            ],
            preampDecibels: 0,
            isEngaged: true,
            peakGuard: true,
            startsEngaged: true
        )
        let tone = (0..<2_048).map { Float(0.5 * sin(2 * Double.pi * 440 * Double($0) / rate)) }

        let output = run(kernel, planar: [tone])[0]

        XCTAssertTrue(output.allSatisfy(\.isFinite))
    }

    func testResetClearsTheFiltersMemory() {
        let kernel = EqualizerKernel(channelCount: 1, sampleRate: rate)
        kernel.configure(bands: [EqualizerBand(type: .bell, frequency: 200, gain: 10, q: 4)], preampDecibels: 0, isEngaged: true, peakGuard: false)
        settle(kernel)
        _ = run(kernel, planar: impulse(length: 32))

        kernel.reset()
        let silence = run(kernel, planar: [[Float](repeating: 0, count: 256)])[0]

        XCTAssertTrue(silence.allSatisfy { $0 == 0 })
    }

    func testTheAnalysisRingHoldsTheMostRecentSamples() {
        let kernel = EqualizerKernel(channelCount: 1, sampleRate: rate)
        kernel.configure(bands: [], preampDecibels: 0, isEngaged: false, peakGuard: false)
        let ramp = (0..<5_000).map { Float($0) / 5_000 }
        _ = run(kernel, planar: [ramp])

        var window = [Float](repeating: 0, count: 100)
        window.withUnsafeMutableBufferPointer { kernel.copyAnalysis(into: $0.baseAddress!, count: 100) }

        XCTAssertEqual(window, Array(ramp[4_900..<5_000]))
    }
}
