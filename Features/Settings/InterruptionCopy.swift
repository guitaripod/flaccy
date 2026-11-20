import FlaccyCore
import Foundation

/// The words for what Flaccy does after another app took the sound.
nonisolated enum InterruptionCopy {

    static var title: String {
        String(localized: "After Another App Plays")
    }

    static func name(_ choice: InterruptionResume) -> String {
        switch choice {
        case .whenQuiet: String(localized: "Resume")
        case .whenHandedBack: String(localized: "Calls and Siri Only")
        case .never: String(localized: "Stay Paused")
        }
    }

    static func detail(_ choice: InterruptionResume) -> String {
        switch choice {
        case .whenQuiet: String(localized: "As soon as the other app goes quiet")
        case .whenHandedBack: String(localized: "Only when iOS hands the sound back")
        case .never: String(localized: "Until you press play")
        }
    }

    static var footer: String {
        String(localized: "A video, a game or a call pauses your music. With Resume, Flaccy plays again once the other app goes quiet. In the background iOS lets Flaccy listen for about half a minute; after that your music picks up when you come back to Flaccy.")
    }
}
