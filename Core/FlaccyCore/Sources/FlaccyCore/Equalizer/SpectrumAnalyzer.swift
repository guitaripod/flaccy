import Foundation

/// Turns the last 2048 samples the equalizer saw into the 110 log-spaced bins
/// the curve screen draws behind its response, in decibels relative to a full
/// scale sine. A Hann window and a plain radix-2 FFT, written out here rather
/// than taken from a platform library so the Mac, the iPhone and Linux draw the
/// same picture. Mirrored in Rust as `linux/shared/src/equalizer/spectrum.rs`.
public final class SpectrumAnalyzer {

    public static let windowSize = 2_048
    public static let binCount = 110
    public static let floorDecibels: Float = -96

    public let sampleRate: Double
    private let window: [Float]
    private let cosines: [Float]
    private let sines: [Float]
    private let windowGain: Float
    private let binEdges: [Int]
    private var real: [Float]
    private var imaginary: [Float]

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        let n = Self.windowSize
        var window = [Float](repeating: 0, count: n)
        var sum: Float = 0
        for i in 0..<n {
            let w = Float(0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(n)))
            window[i] = w
            sum += w
        }
        self.window = window
        windowGain = 2 / sum
        cosines = (0..<(n / 2)).map { Float(cos(-2 * Double.pi * Double($0) / Double(n))) }
        sines = (0..<(n / 2)).map { Float(sin(-2 * Double.pi * Double($0) / Double(n))) }
        real = [Float](repeating: 0, count: n)
        imaginary = [Float](repeating: 0, count: n)

        let nyquist = sampleRate / 2
        let low = EqualizerBand.frequencyRange.lowerBound
        let high = min(EqualizerBand.frequencyRange.upperBound, nyquist * 0.98)
        binEdges = (0...Self.binCount).map { index in
            let f = low * pow(high / low, Double(index) / Double(Self.binCount))
            return min(max(Int((f / sampleRate * Double(n)).rounded()), 1), n / 2 - 1)
        }
    }

    /// Decibel level of each log-spaced bin for the last `windowSize` samples.
    /// A bin narrower than one FFT line reads the line it falls on.
    public func analyze(_ samples: UnsafePointer<Float>) -> [Float] {
        let n = Self.windowSize
        for i in 0..<n {
            real[i] = samples[i] * window[i]
            imaginary[i] = 0
        }
        fft()

        var lines = [Float](repeating: Self.floorDecibels, count: n / 2)
        for i in 1..<(n / 2) {
            let magnitude = (real[i] * real[i] + imaginary[i] * imaginary[i]).squareRoot() * windowGain
            lines[i] = max(20 * log10(max(magnitude, 1e-9)), Self.floorDecibels)
        }

        var bins = [Float](repeating: Self.floorDecibels, count: Self.binCount)
        for bin in 0..<Self.binCount {
            let start = binEdges[bin]
            let end = max(binEdges[bin + 1], start + 1)
            var peak = Self.floorDecibels
            for line in start..<min(end, n / 2) {
                peak = max(peak, lines[line])
            }
            bins[bin] = peak
        }
        return bins
    }

    private func fft() {
        let n = Self.windowSize
        var j = 0
        for i in 1..<n {
            var bit = n >> 1
            while j & bit != 0 {
                j ^= bit
                bit >>= 1
            }
            j ^= bit
            if i < j {
                real.swapAt(i, j)
                imaginary.swapAt(i, j)
            }
        }
        var length = 2
        while length <= n {
            let half = length / 2
            let step = n / length
            var start = 0
            while start < n {
                for k in 0..<half {
                    let wr = cosines[k * step]
                    let wi = sines[k * step]
                    let even = start + k
                    let odd = even + half
                    let tr = real[odd] * wr - imaginary[odd] * wi
                    let ti = real[odd] * wi + imaginary[odd] * wr
                    real[odd] = real[even] - tr
                    imaginary[odd] = imaginary[even] - ti
                    real[even] += tr
                    imaginary[even] += ti
                }
                start += length
            }
            length <<= 1
        }
    }
}
