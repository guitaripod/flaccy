import Foundation

public struct EqualizerBand: Codable, Equatable, Sendable {
    public var type: EqualizerFilterType
    public var frequency: Double
    public var gain: Double
    public var q: Double
    public var isEnabled: Bool

    public static let frequencyRange: ClosedRange<Double> = 20...20_000
    public static let gainRange: ClosedRange<Double> = -12...12
    public static let qRange: ClosedRange<Double> = 0.3...10
    public static let maximumPerProfile = 10

    public init(
        type: EqualizerFilterType = .bell,
        frequency: Double,
        gain: Double = 0,
        q: Double? = nil,
        isEnabled: Bool = true
    ) {
        self.type = type
        self.frequency = frequency
        self.gain = gain
        self.q = q ?? type.defaultQ
        self.isEnabled = isEnabled
    }

    /// The band with every value forced into the range the equalizer allows.
    public func clamped() -> EqualizerBand {
        var band = self
        band.frequency = Self.forced(frequency, into: Self.frequencyRange, orElse: 1_000)
        band.gain = type.hasGain ? Self.forced(gain, into: Self.gainRange, orElse: 0) : 0
        band.q = Self.forced(q, into: Self.qRange, orElse: type.defaultQ)
        return band
    }

    /// `value` inside `range`, or `fallback` when it is not a number at all:
    /// `min` and `max` hand a NaN straight through, and one NaN in a filter
    /// silences the rest of the track.
    private static func forced(_ value: Double, into range: ClosedRange<Double>, orElse fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}

public enum EqualizerKind: String, Codable, Sendable {
    case graphic
    case parametric
}

/// A named equalizer curve. A graphic profile stores what the person placed,
/// the ten target gains at the ISO centres; the filter gains that make the
/// curve pass through those points are derived by `GraphicSolver` and never
/// stored, so presets stay numbers a human can read and the solver can improve
/// without migrating anyone. A parametric profile stores its bands directly.
public struct EqualizerProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var kind: EqualizerKind
    public var targets: [Double]
    public var bands: [EqualizerBand]
    public var isAutoPreamp: Bool
    public var manualPreamp: Double

    public static let preampRange: ClosedRange<Double> = -24...6
    public static let flatID = "builtin.flat"

    public init(
        id: String = UUID().uuidString,
        name: String,
        kind: EqualizerKind,
        targets: [Double] = Array(repeating: 0, count: GraphicSolver.centres.count),
        bands: [EqualizerBand] = [],
        isAutoPreamp: Bool = true,
        manualPreamp: Double = 0
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.targets = targets
        self.bands = bands
        self.isAutoPreamp = isAutoPreamp
        self.manualPreamp = manualPreamp
    }

    public static func graphic(id: String = UUID().uuidString, name: String, targets: [Double]) -> EqualizerProfile {
        EqualizerProfile(id: id, name: name, kind: .graphic, targets: targets)
    }

    public static func parametric(id: String = UUID().uuidString, name: String, bands: [EqualizerBand]) -> EqualizerProfile {
        EqualizerProfile(id: id, name: name, kind: .parametric, bands: bands)
    }

    public var isBuiltIn: Bool {
        id.hasPrefix("builtin.")
    }

    /// The filters the DSP runs and the curve is drawn from.
    public func resolvedBands() -> [EqualizerBand] {
        switch kind {
        case .graphic:
            return GraphicSolver.bands(forTargets: targets)
        case .parametric:
            return bands.map { $0.clamped() }
        }
    }

    /// The preamp in decibels: the automatic headroom, or the person's own.
    public func preamp(for resolved: [EqualizerBand]? = nil) -> Double {
        if isAutoPreamp {
            return Headroom.autoPreamp(for: resolved ?? resolvedBands())
        }
        return min(max(manualPreamp, Self.preampRange.lowerBound), Self.preampRange.upperBound)
    }

    /// True when the stage would change nothing: every filter flat and no preamp.
    /// A flat profile is never given a stage to run in, so playback stays bit-perfect.
    public var isFlat: Bool {
        let resolved = resolvedBands()
        let flatBands = resolved.allSatisfy { band in
            !band.isEnabled || (band.type.hasGain && abs(band.gain) < 0.05 && band.type != .highPass && band.type != .lowPass)
        }
        return flatBands && abs(preamp(for: resolved)) < 0.05
    }
}
