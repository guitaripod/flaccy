import Foundation

/// The equalizer's signal path: a cascade of up to ten biquads, a preamp, a
/// peak guard and a dry/wet crossfade, running on 32-bit float samples with its filter arithmetic in double precision.
///
/// It is the one piece of audio code the clients share. The Apple taps and the
/// Linux GStreamer element each only hand it buffers; the arithmetic, the
/// ramping and the guard are identical, and `linux/shared/src/equalizer/kernel.rs`
/// is pinned to this file by the same impulse-response vectors.
///
/// Everything a render call touches is allocated up front, so `process` never
/// allocates or locks. `configure` is cheap enough to call from the render
/// thread when a new profile arrives. Edits are never abrupt: coefficients and
/// preamp glide over `rampFrames` samples, and the stage crossfades in and out
/// of the dry signal over `crossfadeFrames`, so enabling the equalizer while a
/// song plays does not click.
///
/// It is `@unchecked Sendable` because the engine hands a kernel to one render
/// thread at a time behind a lock, so no two threads ever run it together.
public final class EqualizerKernel: @unchecked Sendable {

    public static let maxSections = EqualizerBand.maximumPerProfile
    public static let rampFrames = 1_024
    public static let crossfadeFrames = 1_024
    public static let guardCeiling: Float = 1
    public static let guardReleaseSeconds: Float = 0.05
    public static let analysisCapacity = 4_096

    public let channelCount: Int
    public let sampleRate: Double

    public private(set) var blockPeak: Float = 0
    public private(set) var guardReduced = false
    public private(set) var analysisWriteIndex = 0

    private let sectionSlots = EqualizerKernel.maxSections * 5
    private let startCoefficients: UnsafeMutablePointer<Double>
    private let targetCoefficients: UnsafeMutablePointer<Double>
    private let liveCoefficients: UnsafeMutablePointer<Double>
    private let delay: UnsafeMutablePointer<Double>
    private let analysis: UnsafeMutablePointer<Float>

    private var liveSections = 0
    private var targetSections = 0
    private var startGain: Double = 1
    private var targetGain: Double = 1
    private var liveGain: Double = 1
    private var wet: Float = 0
    private var targetWet: Float = 0
    private var rampPosition = 0
    private var rampTotal = 0
    private var hasConfiguration = false
    private var peakGuardEnabled = true
    private var guardGain: Float = 1
    private let guardReleaseStep: Float

    public init(channelCount: Int, sampleRate: Double) {
        self.channelCount = max(channelCount, 1)
        self.sampleRate = sampleRate
        let slots = sectionSlots
        startCoefficients = .allocate(capacity: slots)
        targetCoefficients = .allocate(capacity: slots)
        liveCoefficients = .allocate(capacity: slots)
        delay = .allocate(capacity: self.channelCount * Self.maxSections * 2)
        analysis = .allocate(capacity: Self.analysisCapacity)
        delay.initialize(repeating: 0, count: self.channelCount * Self.maxSections * 2)
        analysis.initialize(repeating: 0, count: Self.analysisCapacity)
        for pointer in [startCoefficients, targetCoefficients, liveCoefficients] {
            Self.fillIdentity(pointer, sections: Self.maxSections)
        }
        guardReleaseStep = 1 / max(Self.guardReleaseSeconds * Float(sampleRate), 1)
    }

    deinit {
        startCoefficients.deallocate()
        targetCoefficients.deallocate()
        liveCoefficients.deallocate()
        delay.deallocate()
        analysis.deallocate()
    }

    /// True when the stage is fully crossfaded out, not asked to come back and
    /// no longer holding the guard down: samples pass through untouched.
    public var isBypassed: Bool {
        wet == 0 && targetWet == 0 && guardGain >= 1
    }

    /// Points the stage at a new curve. Called with `isEngaged == false` it
    /// crossfades out and then passes audio through bit for bit.
    ///
    /// The first call decides how the stage begins. A kernel that is born with
    /// the beginning of a song passes `startsEngaged` so the curve is already
    /// in force on the first sample; one that appears under a song already
    /// playing leaves it off and crossfades in, so turning the equalizer on
    /// mid-song does not click.
    public func configure(bands: [EqualizerBand], preampDecibels: Double, isEngaged: Bool, peakGuard: Bool, startsEngaged: Bool = false) {
        let first = !hasConfiguration
        hasConfiguration = true
        peakGuardEnabled = peakGuard

        for slot in 0..<sectionSlots {
            startCoefficients[slot] = liveCoefficients[slot]
        }
        startGain = liveGain

        var count = 0
        for band in bands where band.isEnabled && count < Self.maxSections {
            let c = BiquadMath.coefficients(for: band, sampleRate: sampleRate)
            guard [c.b0, c.b1, c.b2, c.a1, c.a2].allSatisfy(\.isFinite) else { continue }
            let base = count * 5
            targetCoefficients[base] = c.b0
            targetCoefficients[base + 1] = c.b1
            targetCoefficients[base + 2] = c.b2
            targetCoefficients[base + 3] = c.a1
            targetCoefficients[base + 4] = c.a2
            count += 1
        }
        if count < Self.maxSections {
            Self.fillIdentity(targetCoefficients + count * 5, sections: Self.maxSections - count)
        }
        targetSections = count
        targetGain = pow(10, preampDecibels / 20)
        targetWet = isEngaged ? 1 : 0

        if first {
            for slot in 0..<sectionSlots {
                startCoefficients[slot] = targetCoefficients[slot]
                liveCoefficients[slot] = targetCoefficients[slot]
            }
            startGain = targetGain
            liveGain = targetGain
            liveSections = targetSections
            rampTotal = 0
            rampPosition = 0
            wet = startsEngaged && isEngaged ? 1 : 0
        } else {
            rampTotal = Self.rampFrames
            rampPosition = 0
        }
    }

    /// Forgets the filters' memory. Called on a seek or an item change, where
    /// the signal is discontinuous and old state would ring into the new audio.
    public func reset() {
        delay.update(repeating: 0, count: channelCount * Self.maxSections * 2)
        guardGain = 1
    }

    /// Runs `frames` frames in place. `planes` holds one pointer per channel;
    /// consecutive frames of a channel are `planeStride` floats apart, so
    /// planar audio uses a stride of 1 and interleaved audio a stride of the
    /// channel count with `planes[c]` pointing at the c-th sample of the first frame.
    public func process(planes: UnsafePointer<UnsafeMutablePointer<Float>>, planeStride: Int, frames: Int) {
        guard frames > 0 else { return }
        let channels = channelCount

        if isBypassed {
            var peak: Float = 0
            for channel in 0..<channels {
                let plane = planes[channel]
                for frame in 0..<frames {
                    peak = max(peak, abs(plane[frame * planeStride]))
                }
            }
            blockPeak = peak
            guardReduced = false
            feedAnalysis(planes: planes, planeStride: planeStride, frames: frames)
            return
        }

        let sections = max(liveSections, targetSections)
        let maxSections = Self.maxSections
        let wetStep: Float = 1 / Float(Self.crossfadeFrames)
        let useGuard = peakGuardEnabled
        let ceiling = Self.guardCeiling
        let releaseStep = guardReleaseStep
        var peak: Float = 0
        var reduced = false

        for frame in 0..<frames {
            var rampFraction: Double = 1
            let ramping = rampPosition < rampTotal
            if ramping {
                rampPosition += 1
                rampFraction = Double(rampPosition) / Double(rampTotal)
                for slot in 0..<(sections * 5) {
                    let from = startCoefficients[slot]
                    liveCoefficients[slot] = from + (targetCoefficients[slot] - from) * rampFraction
                }
                liveGain = startGain + (targetGain - startGain) * rampFraction
            } else if rampTotal > 0 {
                for slot in 0..<(sections * 5) {
                    liveCoefficients[slot] = targetCoefficients[slot]
                }
                liveGain = targetGain
                liveSections = targetSections
                rampTotal = 0
                rampPosition = 0
            }

            let mix = wet
            if wet < targetWet {
                wet = min(wet + wetStep, targetWet)
            } else if wet > targetWet {
                wet = max(wet - wetStep, targetWet)
            }

            var frameMax: Float = 0
            for channel in 0..<channels {
                let dry = planes[channel][frame * planeStride]
                var value = Double(dry) * liveGain
                let state = delay + channel * maxSections * 2
                for section in 0..<sections {
                    let c = liveCoefficients + section * 5
                    let z = state + section * 2
                    let out = c[0] * value + z[0]
                    z[0] = c[1] * value - c[3] * out + z[1]
                    z[1] = c[2] * value - c[4] * out
                    value = out
                }
                let mixed = dry + (Float(value) - dry) * mix
                planes[channel][frame * planeStride] = mixed
                frameMax = max(frameMax, abs(mixed))
            }

            if useGuard {
                var wanted: Float = 1
                if frameMax > ceiling { wanted = ceiling / frameMax }
                guardGain = min(wanted, guardGain + releaseStep)
                if guardGain < 1 {
                    reduced = reduced || guardGain < 0.999
                    frameMax = 0
                    for channel in 0..<channels {
                        let p = planes[channel] + frame * planeStride
                        p.pointee *= guardGain
                        frameMax = max(frameMax, abs(p.pointee))
                    }
                }
            }
            peak = max(peak, frameMax)
        }

        if rampTotal > 0 && rampPosition >= rampTotal {
            for slot in 0..<(sections * 5) {
                liveCoefficients[slot] = targetCoefficients[slot]
            }
            liveGain = targetGain
            liveSections = targetSections
            rampTotal = 0
            rampPosition = 0
            if targetSections < sections {
                clearDelay(from: targetSections)
            }
        }

        blockPeak = peak
        guardReduced = reduced
        feedAnalysis(planes: planes, planeStride: planeStride, frames: frames)
    }

    /// Copies the most recent `count` mono analysis samples, oldest first, into `output`.
    public func copyAnalysis(into output: UnsafeMutablePointer<Float>, count: Int) {
        let capacity = Self.analysisCapacity
        let n = min(count, capacity)
        var index = (analysisWriteIndex - n + capacity * 2) % capacity
        for i in 0..<n {
            output[i] = analysis[index]
            index = (index + 1) % capacity
        }
    }

    private func feedAnalysis(planes: UnsafePointer<UnsafeMutablePointer<Float>>, planeStride: Int, frames: Int) {
        let capacity = Self.analysisCapacity
        let scale = 1 / Float(channelCount)
        var index = analysisWriteIndex
        for frame in 0..<frames {
            var sum: Float = 0
            for channel in 0..<channelCount {
                sum += planes[channel][frame * planeStride]
            }
            analysis[index] = sum * scale
            index += 1
            if index == capacity { index = 0 }
        }
        analysisWriteIndex = index
    }

    private func clearDelay(from section: Int) {
        let maxSections = Self.maxSections
        for channel in 0..<channelCount {
            let state = delay + channel * maxSections * 2
            for s in section..<maxSections {
                state[s * 2] = 0
                state[s * 2 + 1] = 0
            }
        }
    }

    private static func fillIdentity(_ pointer: UnsafeMutablePointer<Double>, sections: Int) {
        for section in 0..<sections {
            let base = section * 5
            pointer[base] = 1
            pointer[base + 1] = 0
            pointer[base + 2] = 0
            pointer[base + 3] = 0
            pointer[base + 4] = 0
        }
    }
}
