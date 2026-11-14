import FlaccyCore
import Foundation

/// Every word of Describe the Sound, written once for the iPhone and the Mac.
enum EqualizerDescribeCopy {

    static var title: String { String(localized: "Describe the Sound") }
    static var menuTitle: String { String(localized: "Describe the Sound…") }
    static var placeholder: String { String(localized: "Warmer, with softer cymbals") }
    static var changePlaceholder: String { String(localized: "Change it: a little less bass") }
    static var shape: String { String(localized: "Shape It") }
    static var shaping: String { String(localized: "Shaping the curve…") }
    static var addToPresets: String { String(localized: "Add to Presets") }
    static var addAndUse: String { String(localized: "Add and Use") }
    static var hearIt: String { String(localized: "Hear It") }
    /// The name a curve takes when the reply gave none. Read by the service off the main actor.
    nonisolated static var fallbackName: String { String(localized: "Described") }

    /// What the feature does and what leaves the device for it, shown under the field before a curve is made.
    static var explanation: String {
        String(localized: "Say how you want your music to sound and Flaccy shapes an equalizer curve for it. Your words, the kind of device and output you are listening on and the curve in use go to Flaccy's AI. Nothing else leaves this device.")
    }

    /// Sentences one tap asks, so nobody has to think of a first one.
    static var examples: [String] {
        [
            String(localized: "More punch in the drums"),
            String(localized: "Clearer voices"),
            String(localized: "Easy on the ears, late at night"),
            String(localized: "Less boom in the bass"),
        ]
    }

    /// The line under a made curve's name: whether it is what is being heard, and that nothing is kept yet.
    static func hearing(isPlaying: Bool, isHearing: Bool) -> String {
        if !isPlaying { return String(localized: "Play a song to hear this curve before you keep it.") }
        return isHearing
            ? String(localized: "You are hearing this curve. Nothing is saved until you add it.")
            : String(localized: "You are hearing your music as it was. Nothing is saved until you add it.")
    }

    /// "Low shelf · 90 Hz · +3.0 dB", the name of one band of a made curve.
    static func bandTitle(_ band: EqualizerBand) -> String {
        var parts = [EqualizerCopy.typeName(band.type), EqualizerCopy.hertz(band.frequency)]
        if band.type.hasGain { parts.append("\(EqualizerCopy.decibels(band.gain)) dB") }
        return parts.joined(separator: " · ")
    }

    static func added(_ name: String) -> String {
        String(localized: "Saved \u{201C}\(name)\u{201D}")
    }

    /// What went wrong shaping a curve, the cause and what to do next.
    static func failure(_ failure: EqualizerDescriptionFailure) -> String {
        switch failure {
        case .needsEntitlement:
            return String(localized: "Describing a sound uses Flaccy's AI, which comes with Flaccy Lifetime.")
        case .unreachable:
            return String(localized: "Couldn't shape the curve because Flaccy's AI couldn't be reached. Check your connection and try again.")
        case .quotaReached(let resetsAt):
            let time = resetsAt.formatted(date: .omitted, time: .shortened)
            return String(localized: "Couldn't shape the curve because today's AI allowance is used up. It comes back at \(time).")
        case .nothingToShape(let note):
            return note.isEmpty ? String(localized: "That didn't describe a sound an equalizer can shape. Say how you want the music to sound.") : note
        case .unavailable:
            return String(localized: "Couldn't shape the curve because Flaccy's AI is unavailable right now. Try again in a few minutes.")
        }
    }
}
