import Foundation

/// A song's own volume: how far the player raises or lowers one song, in tenths
/// of a decibel, on every client and every copy of that song.
///
/// It rides the equalizer's stage rather than a stage of its own: the level is
/// folded into the preamp, so a change glides over the kernel's ramp instead of
/// stepping, and a raised song always runs the peak guard, which is what lets a
/// quiet master come up without clipping. Mirrored in Rust as
/// `linux/shared/src/equalizer/song_gain.rs`.
public enum SongGain {

    public static let maxTenths = 120
    public static let stepTenths = 5

    /// The equalizer stage a tap or element should run for one song.
    public struct Stage: Equatable, Sendable {
        public var isEngaged: Bool
        public var bands: [EqualizerBand]
        public var preampDecibels: Double
        public var peakGuard: Bool

        public init(isEngaged: Bool, bands: [EqualizerBand], preampDecibels: Double, peakGuard: Bool) {
            self.isEngaged = isEngaged
            self.bands = bands
            self.preampDecibels = preampDecibels
            self.peakGuard = peakGuard
        }
    }

    public static func clamped(_ tenths: Int) -> Int {
        min(max(tenths, -maxTenths), maxTenths)
    }

    public static func decibels(_ tenths: Int) -> Double {
        Double(tenths) / 10
    }

    /// The step nearest to a slider position in decibels.
    public static func snapped(decibels: Double) -> Int {
        guard decibels.isFinite else { return 0 }
        let steps = (decibels * 10 / Double(stepTenths)).rounded()
        return clamped(Int(steps) * stepTenths)
    }

    /// The level `steps` steps away. A level between two steps, which another
    /// client may have set, moves to the neighbouring step in that direction
    /// first, so one press never skips past a step.
    public static func stepped(_ tenths: Int, by steps: Int) -> Int {
        guard steps != 0 else { return clamped(tenths) }
        let below = floorDivided(tenths, by: stepTenths) * stepTenths
        let base = steps > 0 ? below : (below == tenths ? tenths : below + stepTenths)
        return clamped(base + steps * stepTenths)
    }

    /// A level read back from Flaccy Server, which accepts a wider range than these controls offer.
    public static func fromServer(_ value: Int64) -> Int {
        clamped(Int(max(min(value, Int64(maxTenths)), Int64(-maxTenths))))
    }

    /// The equalizer stage with the song's level folded into the preamp. A
    /// song at 0 dB leaves the stage exactly as the equalizer has it, so with
    /// the equalizer off audio still passes untouched.
    public static func stage(isEngaged: Bool, bands: [EqualizerBand], preampDecibels: Double, peakGuard: Bool, tenths: Int) -> Stage {
        let level = clamped(tenths)
        return Stage(
            isEngaged: isEngaged || level != 0,
            bands: bands,
            preampDecibels: preampDecibels + decibels(level),
            peakGuard: peakGuard || level > 0
        )
    }

    /// The level as people read it: "+3.5 dB", "−2 dB", "0 dB", with the
    /// locale's decimal separator and a true minus sign.
    public static func label(_ tenths: Int, locale: Locale = .current) -> String {
        let level = clamped(tenths)
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 1
        let magnitude = formatter.string(from: NSNumber(value: Double(abs(level)) / 10)) ?? "\(Double(abs(level)) / 10)"
        let sign = level > 0 ? "+" : (level < 0 ? "\u{2212}" : "")
        return "\(sign)\(magnitude) dB"
    }

    private static func floorDivided(_ value: Int, by divisor: Int) -> Int {
        let quotient = value / divisor
        return value % divisor < 0 ? quotient - 1 : quotient
    }
}
