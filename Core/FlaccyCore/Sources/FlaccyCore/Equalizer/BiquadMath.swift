import Foundation

/// The five filter shapes the equalizer offers. Shelves and bells carry a
/// gain; the two pass filters only cut, so a gain on them is meaningless.
public enum EqualizerFilterType: String, Codable, CaseIterable, Sendable {
    case bell
    case lowShelf
    case highShelf
    case highPass
    case lowPass

    public var hasGain: Bool {
        self != .highPass && self != .lowPass
    }

    /// The Q a freshly chosen type starts with: shelves and pass filters sit
    /// at the maximally flat 0.71, a bell at a musical 1.0.
    public var defaultQ: Double {
        self == .bell ? 1.0 : 0.71
    }
}

/// One second-order section, normalised by a0, in the form both the Swift and
/// the Rust DSP kernels run: `y = b0*x + z1`, `z1 = b1*x - a1*y + z2`,
/// `z2 = b2*x - a2*y`.
public struct BiquadCoefficients: Equatable, Sendable {
    public var b0: Double
    public var b1: Double
    public var b2: Double
    public var a1: Double
    public var a2: Double

    public init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0
        self.b1 = b1
        self.b2 = b2
        self.a1 = a1
        self.a2 = a2
    }

    public static let identity = BiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)
}

/// Robert Bristow-Johnson's Audio EQ Cookbook, the single source of the
/// equalizer's maths on every client. Mirrored in Rust as
/// `linux/shared/src/equalizer/biquad.rs`; both are pinned by the same golden
/// vectors, so the curve a person sees is the curve they hear everywhere.
public enum BiquadMath {

    /// The rate the curve is drawn at and the graphic solver is solved at.
    /// Playback recomputes coefficients at the file's own rate from the same
    /// filter gains.
    public static let referenceSampleRate = 48_000.0

    /// How close to Nyquist a centre frequency may sit before the cookbook's
    /// warping makes the response meaningless.
    private static let nyquistFraction = 0.45

    public static func coefficients(
        type: EqualizerFilterType,
        frequency: Double,
        gain: Double,
        q: Double,
        sampleRate: Double
    ) -> BiquadCoefficients {
        let f = min(max(frequency, 1), sampleRate * nyquistFraction)
        let w0 = 2 * Double.pi * f / sampleRate
        let cosW = cos(w0)
        let sinW = sin(w0)
        let alpha = sinW / (2 * max(q, 0.05))
        let a = pow(10, gain / 40)

        let b0, b1, b2, a0, a1, a2: Double
        switch type {
        case .bell:
            b0 = 1 + alpha * a
            b1 = -2 * cosW
            b2 = 1 - alpha * a
            a0 = 1 + alpha / a
            a1 = -2 * cosW
            a2 = 1 - alpha / a
        case .lowShelf:
            let s = 2 * a.squareRoot() * alpha
            b0 = a * ((a + 1) - (a - 1) * cosW + s)
            b1 = 2 * a * ((a - 1) - (a + 1) * cosW)
            b2 = a * ((a + 1) - (a - 1) * cosW - s)
            a0 = (a + 1) + (a - 1) * cosW + s
            a1 = -2 * ((a - 1) + (a + 1) * cosW)
            a2 = (a + 1) + (a - 1) * cosW - s
        case .highShelf:
            let s = 2 * a.squareRoot() * alpha
            b0 = a * ((a + 1) + (a - 1) * cosW + s)
            b1 = -2 * a * ((a - 1) + (a + 1) * cosW)
            b2 = a * ((a + 1) + (a - 1) * cosW - s)
            a0 = (a + 1) - (a - 1) * cosW + s
            a1 = 2 * ((a - 1) - (a + 1) * cosW)
            a2 = (a + 1) - (a - 1) * cosW - s
        case .highPass:
            b0 = (1 + cosW) / 2
            b1 = -(1 + cosW)
            b2 = (1 + cosW) / 2
            a0 = 1 + alpha
            a1 = -2 * cosW
            a2 = 1 - alpha
        case .lowPass:
            b0 = (1 - cosW) / 2
            b1 = 1 - cosW
            b2 = (1 - cosW) / 2
            a0 = 1 + alpha
            a1 = -2 * cosW
            a2 = 1 - alpha
        }
        return BiquadCoefficients(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    public static func coefficients(for band: EqualizerBand, sampleRate: Double) -> BiquadCoefficients {
        coefficients(
            type: band.type,
            frequency: band.frequency,
            gain: band.type.hasGain ? band.gain : 0,
            q: band.q,
            sampleRate: sampleRate
        )
    }

    /// Magnitude of one section at `frequency`, in decibels.
    public static func magnitudeDecibels(_ c: BiquadCoefficients, frequency: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        let cw = cos(w)
        let c2w = cos(2 * w)
        let sw = sin(w)
        let s2w = sin(2 * w)
        let nr = c.b0 + c.b1 * cw + c.b2 * c2w
        let ni = -(c.b1 * sw + c.b2 * s2w)
        let dr = 1 + c.a1 * cw + c.a2 * c2w
        let di = -(c.a1 * sw + c.a2 * s2w)
        let num = nr * nr + ni * ni
        let den = dr * dr + di * di
        return 10 * log10(max(num / max(den, 1e-12), 1e-12))
    }

    /// The summed response of every enabled band at `frequency`, in decibels,
    /// without any preamp.
    public static func responseDecibels(
        _ bands: [EqualizerBand],
        frequency: Double,
        sampleRate: Double = referenceSampleRate
    ) -> Double {
        var sum = 0.0
        for band in bands where band.isEnabled {
            sum += magnitudeDecibels(coefficients(for: band, sampleRate: sampleRate), frequency: frequency, sampleRate: sampleRate)
        }
        return sum
    }

    /// `count` frequencies spaced evenly on a log axis between 20 Hz and 20 kHz.
    public static func logFrequencies(count: Int) -> [Double] {
        guard count > 1 else { return [EqualizerBand.frequencyRange.lowerBound] }
        let low = EqualizerBand.frequencyRange.lowerBound
        let high = EqualizerBand.frequencyRange.upperBound
        return (0..<count).map { low * pow(high / low, Double($0) / Double(count - 1)) }
    }

    /// The response sampled on a log axis, ready to draw.
    public static func curve(_ bands: [EqualizerBand], points: Int = 160) -> [Double] {
        let enabled = bands.filter(\.isEnabled)
        let compiled = enabled.map { coefficients(for: $0, sampleRate: referenceSampleRate) }
        return logFrequencies(count: points).map { f in
            compiled.reduce(0.0) { $0 + magnitudeDecibels($1, frequency: f, sampleRate: referenceSampleRate) }
        }
    }
}
