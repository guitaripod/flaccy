import FlaccyCore
import Foundation

/// Every word the equalizer says, written once for the iPhone and the Mac.
/// Preset names are looked up by their core key so the table of numbers in
/// FlaccyCore stays free of localization.
enum EqualizerCopy {

    static var title: String { String(localized: "Equalizer") }

    @MainActor
    static var settingsSummary: String {
        let engine = EqualizerEngine.shared
        guard let running = engine.runningProfile else { return String(localized: "Off") }
        return name(of: running)
    }
    static var customProfileName: String { String(localized: "Custom") }

    static func name(of profile: EqualizerProfile) -> String {
        guard let key = EqualizerPresets.key(forID: profile.id) else { return profile.name }
        return presetName(forKey: key)
    }

    static func presetName(forKey key: String) -> String {
        switch key {
        case "flat": return String(localized: "Flat")
        case "bassBoost": return String(localized: "Bass Boost")
        case "bassReducer": return String(localized: "Bass Reducer")
        case "trebleBoost": return String(localized: "Treble Boost")
        case "trebleReducer": return String(localized: "Treble Reducer")
        case "vocal": return String(localized: "Vocal")
        case "spokenWord": return String(localized: "Spoken Word")
        case "soften": return String(localized: "Soften")
        case "loudness": return String(localized: "Loudness")
        case "acoustic": return String(localized: "Acoustic")
        case "classical": return String(localized: "Classical")
        case "rock": return String(localized: "Rock")
        case "electronic": return String(localized: "Electronic")
        case "hipHop": return String(localized: "Hip-Hop")
        case "jazz": return String(localized: "Jazz")
        case "pop": return String(localized: "Pop")
        default: return key
        }
    }

    static func presetSubtitle(forKey key: String) -> String {
        switch key {
        case "flat": return String(localized: "No processing, bit-perfect")
        case "bassBoost": return String(localized: "A fuller low end")
        case "bassReducer": return String(localized: "Tighter, less boom")
        case "trebleBoost": return String(localized: "More air and sparkle")
        case "trebleReducer": return String(localized: "Less sizzle on bright records")
        case "vocal": return String(localized: "Voices step forward")
        case "spokenWord": return String(localized: "Podcasts and audiobooks")
        case "soften": return String(localized: "Tames harsh highs")
        case "loudness": return String(localized: "Fuller sound at low volume")
        case "acoustic": return String(localized: "Natural strings and room")
        case "classical": return String(localized: "Open and airy")
        case "rock": return String(localized: "Punch and bite")
        case "electronic": return String(localized: "Deep lows, bright top")
        case "hipHop": return String(localized: "Heavy low end, clear vocals")
        case "jazz": return String(localized: "Warm and smooth")
        case "pop": return String(localized: "Present midrange")
        default: return ""
        }
    }

    static func typeName(_ type: EqualizerFilterType) -> String {
        switch type {
        case .bell: return String(localized: "Bell")
        case .lowShelf: return String(localized: "Low shelf")
        case .highShelf: return String(localized: "High shelf")
        case .highPass: return String(localized: "High-pass")
        case .lowPass: return String(localized: "Low-pass")
        }
    }

    enum Status: Equatable {
        case off
        case flat
        case processing
        case comparing
    }

    static func status(_ status: Status) -> String {
        switch status {
        case .off: return String(localized: "Off · bit-perfect")
        case .flat: return String(localized: "Flat · bit-perfect")
        case .processing: return String(localized: "Processing · 32-bit float")
        case .comparing: return String(localized: "Hearing original · level-matched")
        }
    }

    static func decibels(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded == 0 { return "0.0" }
        return (rounded > 0 ? "+" : "\u{2212}") + String(format: "%.1f", abs(rounded))
    }

    static func hertz(_ value: Double) -> String {
        if value >= 1000 {
            let kilo = value / 1000
            let text = kilo >= 10 || abs(kilo - kilo.rounded()) < 0.05 ? String(Int(kilo.rounded())) : String(format: "%.1f", kilo)
            return String(localized: "\(text) kHz")
        }
        return String(localized: "\(Int(value.rounded())) Hz")
    }

    static func shortHertz(_ value: Double) -> String {
        if value >= 1000 {
            let kilo = value / 1000
            return (kilo >= 10 || abs(kilo - kilo.rounded()) < 0.05 ? String(Int(kilo.rounded())) : String(format: "%.1f", kilo)) + "k"
        }
        return String(Int(value.rounded()))
    }

    static func q(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    /// A profile's name without the "(Simple)" or "(Advanced)" a conversion
    /// added, however many times it was converted, so a copy of a copy keeps one suffix.
    static func baseName(of name: String) -> String {
        let suffixes = Set([
            convertedName(base: "", to: .parametric),
            convertedName(base: "", to: .graphic),
            " (Advanced)",
            " (Simple)",
        ])
        var base = name.trimmingCharacters(in: .whitespaces)
        while let suffix = suffixes.first(where: { base.hasSuffix($0) }) {
            let rest = String(base.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            guard !rest.isEmpty else { break }
            base = rest
        }
        return base
    }

    static func convertedName(base: String, to kind: EqualizerKind) -> String {
        switch kind {
        case .parametric: return String(localized: "\(base) (Advanced)")
        case .graphic: return String(localized: "\(base) (Simple)")
        }
    }

    static func outputChanged(name: String, profile: String) -> String {
        String(localized: "\(name) · \(profile)")
    }
}
