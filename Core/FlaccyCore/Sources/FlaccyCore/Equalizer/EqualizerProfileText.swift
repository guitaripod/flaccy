import Foundation

/// Equalizer profiles as text: the format Equalizer APO and AutoEq publish, so
/// a headphone correction copied from the web imports as it is and a profile
/// exported here opens in the tools people already use.
///
/// Reads `Preamp:`, `Filter n: ON PK|LS|LSC|HS|HSC|LP|LPQ|HP|HPQ Fc … Hz Gain … dB Q …`
/// and `GraphicEQ:` point lists. Writes the same lines plus two comment lines
/// of its own that let a graphic profile round-trip exactly. Anything else in
/// the text is ignored, and text with no filters at all is refused whole.
/// Mirrored in Rust as `linux/shared/src/equalizer/profile_text.rs`.
public enum EqualizerProfileText {

    public struct Parsed: Equatable, Sendable {
        public var profile: EqualizerProfile
        /// Filters beyond the ten a profile holds, or of a kind with no equivalent here.
        public var droppedFilters: Int
    }

    private static let graphicComment = "# FlaccyGraphic:"
    private static let nameComment = "# Flaccy Equalizer:"
    private static let autoPreampTolerance = 0.06

    public static func parse(_ text: String, fallbackName: String) -> Parsed? {
        var name = fallbackName
        var preamp: Double?
        var filters: [EqualizerBand] = []
        var droppedKinds = 0
        var graphicTargets: [Double]?
        var graphicPoints: [(Double, Double)] = []

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let lower = line.lowercased()

            if line.hasPrefix(nameComment) {
                let value = line.dropFirst(nameComment.count).trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { name = value }
            } else if line.hasPrefix(graphicComment) {
                let values = line.dropFirst(graphicComment.count).split(separator: " ").compactMap { finiteNumber($0) }
                if values.count == GraphicSolver.centres.count { graphicTargets = values }
            } else if lower.hasPrefix("preamp:") {
                preamp = firstNumber(in: String(line.dropFirst("preamp:".count)))
            } else if lower.hasPrefix("graphiceq:") {
                graphicPoints = parseGraphicPoints(String(line.dropFirst("graphiceq:".count)))
            } else if lower.hasPrefix("filter") {
                switch parseFilter(line) {
                case .band(let band): filters.append(band)
                case .unsupported: droppedKinds += 1
                case .none: break
                }
            }
        }

        if let targets = graphicTargets {
            let profile = withPreamp(EqualizerProfile.graphic(name: name, targets: targets.map(clampGain)), preamp: preamp)
            return Parsed(profile: profile, droppedFilters: 0)
        }
        if !filters.isEmpty {
            let kept = strongest(filters, limit: EqualizerBand.maximumPerProfile)
            let profile = withPreamp(EqualizerProfile.parametric(name: name, bands: kept), preamp: preamp)
            return Parsed(profile: profile, droppedFilters: filters.count - kept.count + droppedKinds)
        }
        if graphicPoints.count >= 2 {
            let targets = GraphicSolver.centres.map { clampGain(interpolate(graphicPoints, at: $0)) }
            let profile = withPreamp(EqualizerProfile.graphic(name: name, targets: targets), preamp: preamp)
            return Parsed(profile: profile, droppedFilters: 0)
        }
        return nil
    }

    public static func write(_ profile: EqualizerProfile) -> String {
        let resolved = profile.resolvedBands()
        var lines = ["\(nameComment) \(profile.name)"]
        if profile.kind == .graphic {
            lines.append("\(graphicComment) " + profile.targets.map(format).joined(separator: " "))
        }
        lines.append("Preamp: \(format(profile.preamp(for: resolved))) dB")
        for (index, band) in resolved.enumerated() {
            let state = band.isEnabled ? "ON" : "OFF"
            var line = "Filter \(index + 1): \(state) \(token(for: band.type)) Fc \(format(band.frequency)) Hz"
            if band.type.hasGain { line += " Gain \(format(band.gain)) dB" }
            line += " Q \(format(band.q))"
            lines.append(line)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private enum FilterResult {
        case band(EqualizerBand)
        case unsupported
        case none
    }

    private static func parseFilter(_ line: String) -> FilterResult {
        guard let colon = line.firstIndex(of: ":") else { return .none }
        let tokens = line[line.index(after: colon)...].split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard tokens.count >= 2 else { return .none }
        let enabled = tokens[0].uppercased() != "OFF"
        let rest = Array(tokens.dropFirst(tokens[0].uppercased() == "ON" || tokens[0].uppercased() == "OFF" ? 1 : 0))
        guard let kind = rest.first?.uppercased() else { return .none }
        guard let type = type(for: kind) else { return .unsupported }

        var frequency: Double?
        var gain = 0.0
        var q: Double?
        var index = 1
        while index < rest.count {
            let key = rest[index].uppercased()
            if key == "FC", index + 1 < rest.count {
                frequency = finiteNumber(rest[index + 1])
                index += 2
            } else if key == "GAIN", index + 1 < rest.count {
                gain = finiteNumber(rest[index + 1]) ?? 0
                index += 2
            } else if key == "Q", index + 1 < rest.count {
                q = finiteNumber(rest[index + 1])
                index += 2
            } else {
                index += 1
            }
        }
        guard let frequency else { return .none }
        let band = EqualizerBand(type: type, frequency: frequency, gain: gain, q: q, isEnabled: enabled).clamped()
        return .band(band)
    }

    private static func type(for token: String) -> EqualizerFilterType? {
        switch token {
        case "PK", "PEQ": return .bell
        case "LS", "LSC", "LSQ": return .lowShelf
        case "HS", "HSC", "HSQ": return .highShelf
        case "LP", "LPQ": return .lowPass
        case "HP", "HPQ": return .highPass
        default: return nil
        }
    }

    private static func token(for type: EqualizerFilterType) -> String {
        switch type {
        case .bell: return "PK"
        case .lowShelf: return "LSC"
        case .highShelf: return "HSC"
        case .highPass: return "HPQ"
        case .lowPass: return "LPQ"
        }
    }

    private static func parseGraphicPoints(_ text: String) -> [(Double, Double)] {
        text.split(separator: ";").compactMap { pair in
            let parts = pair.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2, let f = finiteNumber(parts[0]), let g = finiteNumber(parts[1]) else { return nil }
            return (f, g)
        }.sorted { $0.0 < $1.0 }
    }

    private static func interpolate(_ points: [(Double, Double)], at frequency: Double) -> Double {
        if frequency <= points[0].0 { return points[0].1 }
        if let last = points.last, frequency >= last.0 { return last.1 }
        for index in 1..<points.count where frequency <= points[index].0 {
            let (f0, g0) = points[index - 1]
            let (f1, g1) = points[index]
            guard f1 > f0 else { return g1 }
            let t = (log(frequency) - log(f0)) / (log(f1) - log(f0))
            return g0 + (g1 - g0) * t
        }
        return 0
    }

    private static func strongest(_ filters: [EqualizerBand], limit: Int) -> [EqualizerBand] {
        guard filters.count > limit else { return filters }
        let weight: (EqualizerBand) -> Double = { $0.type.hasGain ? abs($0.gain) : EqualizerBand.gainRange.upperBound }
        let keep = Set(
            filters.enumerated()
                .sorted { weight($0.element) > weight($1.element) }
                .prefix(limit)
                .map(\.offset)
        )
        return filters.enumerated().filter { keep.contains($0.offset) }.map(\.element)
    }

    private static func withPreamp(_ profile: EqualizerProfile, preamp: Double?) -> EqualizerProfile {
        var result = profile
        guard let preamp else { return result }
        let auto = Headroom.autoPreamp(for: result.resolvedBands())
        if abs(preamp - auto) <= autoPreampTolerance {
            result.isAutoPreamp = true
        } else {
            result.isAutoPreamp = false
            result.manualPreamp = min(max(preamp, EqualizerProfile.preampRange.lowerBound), EqualizerProfile.preampRange.upperBound)
        }
        return result
    }

    /// A number the text really holds: `Double` also parses "nan" and "inf",
    /// which would otherwise travel into the filters and silence the track.
    private static func finiteNumber<S: StringProtocol>(_ text: S) -> Double? {
        guard let value = Double(text), value.isFinite else { return nil }
        return value
    }

    private static func clampGain(_ value: Double) -> Double {
        min(max(value, EqualizerBand.gainRange.lowerBound), EqualizerBand.gainRange.upperBound)
    }

    private static func firstNumber(in text: String) -> Double? {
        text.split(whereSeparator: { $0 == " " || $0 == "\t" }).lazy.compactMap { finiteNumber($0) }.first
    }

    /// Two decimals with trailing zeros trimmed, locale independent, so every client writes the same bytes.
    private static func format(_ value: Double) -> String {
        var text = String(format: "%.2f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text == "-0" ? "0" : text
    }
}
