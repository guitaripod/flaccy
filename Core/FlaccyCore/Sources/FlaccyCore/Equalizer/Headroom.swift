import Foundation

/// How much to turn the signal down so the equalizer's boosts cannot clip.
///
/// The preamp is minus the peak of the summed response, rounded up to the next
/// 0.1 dB. The summed curve is what is measured, not the sum of the band gains:
/// narrow bands that do not overlap would otherwise overstate the peak. A
/// coarse sweep finds where the peaks are and each is then refined, because a
/// bell with a high Q can sit between two sweep points and be a quarter of a
/// decibel taller than either. Mirrored in Rust as
/// `linux/shared/src/equalizer/headroom.rs`.
public enum Headroom {

    private static let sweepPoints = 400
    private static let negligibleBoost = 0.05
    private static let refinementWindow = 1.0
    private static let refinementSteps = 40

    /// The largest boost anywhere between 20 Hz and 20 kHz, never below 0 dB.
    public static func peakBoost(of bands: [EqualizerBand]) -> Double {
        let rate = BiquadMath.referenceSampleRate
        let compiled = bands.filter(\.isEnabled).map { BiquadMath.coefficients(for: $0, sampleRate: rate) }
        guard !compiled.isEmpty else { return 0 }

        let level: (Double) -> Double = { f in
            compiled.reduce(0.0) { $0 + BiquadMath.magnitudeDecibels($1, frequency: f, sampleRate: rate) }
        }
        let frequencies = BiquadMath.logFrequencies(count: sweepPoints)
        let levels = frequencies.map(level)
        var peak = max(levels.max() ?? 0, 0)

        for index in levels.indices where levels[index] >= peak - refinementWindow {
            let before = index > 0 ? levels[index - 1] : -Double.infinity
            let after = index < levels.count - 1 ? levels[index + 1] : -Double.infinity
            guard levels[index] >= before, levels[index] >= after else { continue }
            let low = frequencies[max(index - 1, 0)]
            let high = frequencies[min(index + 1, frequencies.count - 1)]
            peak = max(peak, refinedPeak(between: low, and: high, level: level))
        }
        return peak
    }

    /// A curve that only cuts can still ripple a hundredth of a decibel above
    /// zero where bells overlap; that is not worth turning anything down for.
    public static func autoPreamp(for bands: [EqualizerBand]) -> Double {
        let peak = peakBoost(of: bands)
        guard peak >= negligibleBoost else { return 0 }
        let rounded = (peak * 10 - 1e-6).rounded(.up) / 10
        return rounded <= 0 ? 0 : -rounded
    }

    private static func refinedPeak(between low: Double, and high: Double, level: (Double) -> Double) -> Double {
        var a = log(low)
        var b = log(high)
        var best = max(level(low), level(high))
        for _ in 0..<refinementSteps {
            let m1 = a + (b - a) / 3
            let m2 = b - (b - a) / 3
            let l1 = level(exp(m1))
            let l2 = level(exp(m2))
            best = max(best, l1, l2)
            if l1 < l2 { a = m1 } else { b = m2 }
        }
        return best
    }
}
