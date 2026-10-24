import Foundation

/// The ten-band graphic equalizer, solved so the curve passes through the
/// points a person places.
///
/// A classic graphic equalizer sums ten overlapping bells, so a slider set to
/// +6 dB is heard at roughly +7 dB where its neighbours reinforce it. Here the
/// ten filter gains are solved so the summed response meets every target at
/// its centre: a 10 by 10 interaction matrix solved by elimination, refined by
/// three Newton passes against the exact response. Mirrored in Rust as
/// `linux/shared/src/equalizer/graphic.rs`.
public enum GraphicSolver {

    /// ISO third-octave-spaced centres, one octave apart.
    public static let centres: [Double] = [32, 64, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]

    /// The Q whose bandwidth is one octave, so adjacent bells sum smoothly.
    public static let q = 1.41

    /// The most a single solved filter may be pushed, so an extreme
    /// alternating curve cannot ask for an unreasonable boost.
    public static let filterGainLimit = 18.0

    private static let probeGain = 6.0
    private static let refinementPasses = 3

    private static let interaction: [[Double]] = {
        let rate = BiquadMath.referenceSampleRate
        return centres.map { probe in
            centres.map { centre in
                let c = BiquadMath.coefficients(type: .bell, frequency: centre, gain: probeGain, q: q, sampleRate: rate)
                return BiquadMath.magnitudeDecibels(c, frequency: probe, sampleRate: rate) / probeGain
            }
        }
    }()

    /// The ten targets that best stand in for an arbitrary curve: its response
    /// at each centre, settled onto half decibels and held inside the slider range.
    public static func targets(approximating bands: [EqualizerBand]) -> [Double] {
        centres.map { centre in
            let heard = BiquadMath.responseDecibels(bands, frequency: centre)
            let stepped = (heard / EqualizerPlot.gainStep).rounded() * EqualizerPlot.gainStep
            return min(max(stepped, EqualizerBand.gainRange.lowerBound), EqualizerBand.gainRange.upperBound)
        }
    }

    /// The ten bells, at their centres, whose summed response meets `targets`.
    public static func bands(forTargets targets: [Double]) -> [EqualizerBand] {
        let padded = (0..<centres.count).map { $0 < targets.count ? targets[$0] : 0 }
        let gains = solve(targets: padded)
        return zip(centres, gains).map { centre, gain in
            EqualizerBand(type: .bell, frequency: centre, gain: gain, q: q)
        }
    }

    public static func solve(targets: [Double]) -> [Double] {
        var x = solveLinear(interaction, targets)
        for _ in 0..<refinementPasses {
            let bands = zip(centres, x).map { EqualizerBand(type: .bell, frequency: $0, gain: $1, q: q) }
            let residual = zip(centres, targets).enumerated().map { index, pair in
                pair.1 - BiquadMath.responseDecibels(bands, frequency: pair.0)
            }
            let step = solveLinear(interaction, residual)
            x = zip(x, step).map { $0 + $1 }
        }
        return x.map { min(max($0, -filterGainLimit), filterGainLimit) }
    }

    private static func solveLinear(_ a: [[Double]], _ b: [Double]) -> [Double] {
        let n = b.count
        var m = (0..<n).map { row in a[row] + [b[row]] }
        for column in 0..<n {
            var pivot = column
            for row in (column + 1)..<n where abs(m[row][column]) > abs(m[pivot][column]) {
                pivot = row
            }
            m.swapAt(column, pivot)
            for row in (column + 1)..<n {
                let factor = m[row][column] / m[column][column]
                for k in column...n {
                    m[row][k] -= factor * m[column][k]
                }
            }
        }
        var x = [Double](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var sum = m[row][n]
            for k in (row + 1)..<n {
                sum -= m[row][k] * x[k]
            }
            x[row] = sum / m[row][row]
        }
        return x
    }
}
