import Foundation

/// What a clip's audio looks like frame by frame: `bands[frame]` holds one
/// value per frequency band and `levels[frame]` the loudness, all 0 to 1.
public struct LyricShareAnalysis: Sendable, Equatable {
    public var bands: [[Float]]
    public var levels: [Float]

    public init(bands: [[Float]], levels: [Float]) {
        self.bands = bands
        self.levels = levels
    }

    /// A frame's bands, or a quiet row past either end.
    public func bands(at frame: Int) -> [Float] {
        bands.indices.contains(frame) ? bands[frame] : [Float](repeating: 0, count: LyricShareSpectrum.bandCount)
    }

    public func level(at frame: Int) -> Float {
        levels.indices.contains(frame) ? levels[frame] : 0
    }
}

/// Turns a clip's audio into the bands and levels its visualizer draws. Pure
/// arithmetic on a mono signal, so every client draws the same bars. Mirrored
/// in Rust as `linux/shared/src/lyric_share/spectrum.rs`.
public enum LyricShareSpectrum {

    public static let bandCount = 24
    public static let fftSize = 2048
    public static let lowHz = 50.0
    public static let highHz = 16_000.0
    /// The quietest band that still shows, relative to a full-scale sine.
    public static let bandFloorDB = -60.0
    /// The quietest window that still moves the level.
    public static let levelFloorDB = -45.0
    /// How much of the way to a louder value a frame goes, and to a quieter one.
    public static let attack = 0.65
    public static let release = 0.22

    /// Analyses `frames` frames at `fps`, each centred on its moment of the
    /// signal with zeros beyond either end. A band is the strongest bin it
    /// covers, scaled so a full-scale sine reads 0 dB, mapped from the floor
    /// to 1; the level is the window's RMS mapped the same way. Both are
    /// smoothed frame to frame, quick to rise and slow to fall.
    public static func analyze(mono: [Float], sampleRate: Double, frames: Int, fps: Int) -> LyricShareAnalysis {
        let size = fftSize
        let half = size / 2
        let window = (0..<size).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(size)) }
        let windowSum = window.reduce(0, +)
        let edges = bandEdges(sampleRate: sampleRate)
        let twiddles = (0..<half).map { index -> (Double, Double) in
            let angle = -2 * Double.pi * Double(index) / Double(size)
            return (cos(angle), sin(angle))
        }
        var bands: [[Float]] = []
        var levels: [Float] = []
        bands.reserveCapacity(frames)
        levels.reserveCapacity(frames)
        var smoothedBands = [Double](repeating: 0, count: bandCount)
        var smoothedLevel = 0.0
        var real = [Double](repeating: 0, count: size)
        var imaginary = [Double](repeating: 0, count: size)
        for frame in 0..<max(frames, 0) {
            let centre = Int(Double(frame) / Double(fps) * sampleRate)
            let from = centre - half
            var energy = 0.0
            for index in 0..<size {
                let at = from + index
                let sample = at >= 0 && at < mono.count ? Double(mono[at]) : 0
                energy += sample * sample
                real[index] = sample * window[index]
                imaginary[index] = 0
            }
            transform(&real, &imaginary, twiddles: twiddles)
            for band in 0..<bandCount {
                var peak = 0.0
                for bin in edges[band]..<edges[band + 1] {
                    let magnitude = (real[bin] * real[bin] + imaginary[bin] * imaginary[bin]).squareRoot()
                    peak = max(peak, magnitude)
                }
                let amplitude = peak * 2 / windowSum
                let value = scaled(decibels(amplitude), floor: bandFloorDB)
                smoothedBands[band] = smooth(smoothedBands[band], toward: value)
            }
            let rms = (energy / Double(size)).squareRoot()
            smoothedLevel = smooth(smoothedLevel, toward: scaled(decibels(rms), floor: levelFloorDB))
            bands.append(smoothedBands.map { Float($0) })
            levels.append(Float(smoothedLevel))
        }
        return LyricShareAnalysis(bands: bands, levels: levels)
    }

    /// The FFT bin each band starts at, plus where the last one ends. Bands
    /// are spaced evenly in pitch from `lowHz` to `highHz`, each at least one
    /// bin wide, none past the Nyquist bin.
    static func bandEdges(sampleRate: Double) -> [Int] {
        let half = fftSize / 2
        var edges: [Int] = []
        var previous = 0
        for band in 0...bandCount {
            let hertz = lowHz * pow(highHz / lowHz, Double(band) / Double(bandCount))
            var bin = Int((hertz * Double(fftSize) / sampleRate).rounded(.up))
            bin = min(max(bin, band == 0 ? 1 : previous + 1), half)
            edges.append(bin)
            previous = bin
        }
        for band in stride(from: bandCount - 1, through: 0, by: -1) where edges[band] >= edges[band + 1] {
            edges[band] = max(edges[band + 1] - 1, 0)
        }
        return edges
    }

    private static func decibels(_ amplitude: Double) -> Double {
        20 * log10(amplitude + 1e-9)
    }

    private static func scaled(_ decibels: Double, floor: Double) -> Double {
        min(max((decibels - floor) / -floor, 0.0), 1.0)
    }

    private static func smooth(_ previous: Double, toward value: Double) -> Double {
        previous + (value - previous) * (value > previous ? attack : release)
    }

    /// An in-place iterative radix-2 FFT.
    private static func transform(_ real: inout [Double], _ imaginary: inout [Double], twiddles: [(Double, Double)]) {
        let count = real.count
        var target = 0
        for index in 0..<count {
            if index < target {
                real.swapAt(index, target)
                imaginary.swapAt(index, target)
            }
            var bit = count >> 1
            while bit > 0 && target & bit != 0 {
                target ^= bit
                bit >>= 1
            }
            target |= bit
        }
        var length = 2
        while length <= count {
            let step = count / length
            let halfLength = length / 2
            var start = 0
            while start < count {
                for offset in 0..<halfLength {
                    let (cosine, sine) = twiddles[offset * step]
                    let upper = start + offset
                    let lower = upper + halfLength
                    let rotatedReal = real[lower] * cosine - imaginary[lower] * sine
                    let rotatedImaginary = real[lower] * sine + imaginary[lower] * cosine
                    real[lower] = real[upper] - rotatedReal
                    imaginary[lower] = imaginary[upper] - rotatedImaginary
                    real[upper] += rotatedReal
                    imaginary[upper] += rotatedImaginary
                }
                start += length
            }
            length <<= 1
        }
    }
}
