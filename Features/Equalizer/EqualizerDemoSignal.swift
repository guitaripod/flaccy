#if DEBUG
import FlaccyCore
import Foundation

/// A made-up program signal for the store captures: the seeded library's audio
/// is silence, so the spectrum behind the curve would be flat. This draws the
/// spectrum of an imaginary record, then runs it through the curve in force, so
/// the picture still moves with every edit. Never reachable in a release build.
enum EqualizerDemoSignal {

    static func spectrum(time: Double, bands: [EqualizerBand], preampDecibels: Double) -> [Float] {
        let compiled = bands.filter(\.isEnabled).map { BiquadMath.coefficients(for: $0, sampleRate: BiquadMath.referenceSampleRate) }
        let low = EqualizerBand.frequencyRange.lowerBound
        let high = EqualizerBand.frequencyRange.upperBound
        return (0..<SpectrumAnalyzer.binCount).map { index in
            let frequency = low * pow(high / low, (Double(index) + 0.5) / Double(SpectrumAnalyzer.binCount))
            let tilt = -4.5 * log2(frequency / 1_000)
            let octave = log2(frequency)
            let wobble = 3.2 * sin(octave * 2.3 + time * 1.7) + 2.2 * sin(octave * 5.1 - time * 2.9) + 1.4 * sin(octave * 9.7 + time * 4.3)
            let beat = pow(max(0, sin(time * 7.2)), 3)
            let kick = frequency < 160 ? 9 * beat * exp(-pow(log2(frequency / 60), 2)) : 0
            let air = frequency > 12_000 ? -10 * (frequency - 12_000) / 8_000 : 0
            let response = compiled.reduce(0.0) { $0 + BiquadMath.magnitudeDecibels($1, frequency: frequency, sampleRate: BiquadMath.referenceSampleRate) }
            let level = -38 + tilt + wobble + kick + air + response + preampDecibels
            return Float(min(max(level, -96), -6))
        }
    }

    static func meter(time: Double) -> EqualizerMeter {
        let breathing = 0.58 + 0.06 * sin(time * 2.1)
        return EqualizerMeter(peak: Float(breathing), guardReduced: false)
    }
}
#endif
