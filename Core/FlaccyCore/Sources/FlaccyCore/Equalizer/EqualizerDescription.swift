import Foundation

/// What is sent to have a sentence about sound turned into a curve: the sentence, the listener's language, the kind
/// of thing the music plays through, the kind of device and the bands in force. Nothing else leaves the device for it.
public struct EqualizerDescriptionRequest: Encodable, Equatable, Sendable {
    public struct Band: Encodable, Equatable, Sendable {
        public let type: String
        public let frequency: Double
        public let gain: Double
        public let q: Double
    }

    public let request: String
    public let language: String
    public let output: String
    public let device: String
    public let bands: [Band]
}

/// The curve as flaccy-api answers a sentence, before this device has checked it.
public struct DescribedCurve: Decodable, Equatable, Sendable {
    public struct Band: Decodable, Equatable, Sendable {
        public let type: String
        public let frequency: Double
        public let gain: Double
        public let q: Double
        public let reason: String

        public init(type: String, frequency: Double, gain: Double, q: Double, reason: String) {
            self.type = type
            self.frequency = frequency
            self.gain = gain
            self.q = q
            self.reason = reason
        }
    }

    public let name: String
    public let bands: [Band]
    public let note: String

    public init(name: String, bands: [Band], note: String) {
        self.name = name
        self.bands = bands
        self.note = note
    }
}

/// A curve made from a sentence and checked here: a profile to hear and keep, with what each of its bands is for.
public struct DescribedEqualizer: Equatable, Sendable {
    public let profile: EqualizerProfile
    /// One sentence for each band of the profile, in the profile's order; empty where the reply gave none.
    public let reasons: [String]
    /// What the sentence asked for that an equalizer cannot do, or an empty string.
    public let note: String
}

/// Turning a sentence about sound into a curve: what is sent, and what a reply must be before it is played.
/// The service clamps every band and this clamps again, so nothing a model wrote reaches the audio unchecked:
/// a band of no kind is dropped, every value is forced into the equalizer's ranges, a pass filter is kept from
/// ringing, a band that would do nothing is left out, and a curve whose boosts add up past the top of the plot is
/// scaled down until they fit.
public enum EqualizerDescription {
    public static let longestRequest = 300
    /// The most the summed curve may boost anywhere: the top of the equalizer's plot.
    public static let highestBoost = EqualizerBand.gainRange.upperBound
    /// A gain smaller than this changes nothing a person hears, so its band is not kept.
    public static let leastGain = 0.25
    /// The highest Q a described high-pass or low-pass takes. Above it the filter peaks at its corner, by 20 dB
    /// at Q 10, and that boost has no gain to turn down.
    public static let highestPassQ = 1.0
    static let longestName = 40
    static let longestReason = 200
    static let longestNote = 240

    /// The request for `sentence`, with the bands the profile in force resolves to. A flat profile sends none.
    public static func request(_ sentence: String, language: String, output: String, device: String, inForce: EqualizerProfile) -> EqualizerDescriptionRequest {
        let bands = inForce.isFlat ? [] : inForce.resolvedBands().filter { $0.isEnabled && isAudible($0) }
        return EqualizerDescriptionRequest(
            request: String(oneLine(sentence).prefix(longestRequest)),
            language: language,
            output: output,
            device: device,
            bands: bands.prefix(EqualizerBand.maximumPerProfile).map {
                EqualizerDescriptionRequest.Band(type: $0.type.rawValue, frequency: rounded($0.frequency, places: 1), gain: rounded($0.gain, places: 1), q: rounded($0.q, places: 2))
            })
    }

    /// The reply as a curve that is safe to play, or nil when no band of it is one the equalizer has.
    public static func settle(_ curve: DescribedCurve, fallbackName: String) -> DescribedEqualizer? {
        var kept: [(band: EqualizerBand, reason: String)] = []
        for described in curve.bands {
            guard let type = EqualizerFilterType(rawValue: described.type), described.frequency.isFinite, described.gain.isFinite, described.q.isFinite else { continue }
            var band = EqualizerBand(type: type, frequency: described.frequency, gain: described.gain, q: described.q).clamped()
            if !type.hasGain { band.q = min(band.q, highestPassQ) }
            guard isAudible(band) else { continue }
            kept.append((band, String(oneLine(described.reason).prefix(longestReason))))
            if kept.count == EqualizerBand.maximumPerProfile { break }
        }
        guard !kept.isEmpty else { return nil }
        let bands = tamed(kept.map(\.band))
        let name = String(oneLine(curve.name).prefix(longestName))
        return DescribedEqualizer(
            profile: .parametric(name: name.isEmpty ? fallbackName : name, bands: bands),
            reasons: kept.map(\.reason),
            note: String(oneLine(curve.note).prefix(longestNote)))
    }

    /// The bands with every gain scaled down together until the summed curve boosts no more than `highestBoost`.
    /// Bands that only overlap a little add up to less than their gains, so the curve is measured, not the gains.
    static func tamed(_ bands: [EqualizerBand]) -> [EqualizerBand] {
        var result = bands
        for _ in 0..<4 {
            let peak = Headroom.peakBoost(of: result)
            guard peak > highestBoost + 0.05 else { break }
            let scale = highestBoost / peak
            result = result.map { band in
                var scaled = band
                if band.type.hasGain { scaled.gain = rounded(band.gain * scale, places: 1) }
                return scaled
            }
        }
        return result
    }

    private static func isAudible(_ band: EqualizerBand) -> Bool {
        !band.type.hasGain || abs(band.gain) >= leastGain
    }

    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func rounded(_ value: Double, places: Int) -> Double {
        let scale = pow(10, Double(places))
        return (value * scale).rounded() / scale
    }
}
