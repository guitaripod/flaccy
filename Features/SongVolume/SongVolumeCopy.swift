import FlaccyCore
import Foundation

/// Every word a song's own volume says, written once for the iPhone and the Mac.
enum SongVolumeCopy {

    static var title: String { String(localized: "Song Volume") }
    static var menuTitle: String { String(localized: "Song Volume…") }
    static var explanation: String {
        String(localized: "Plays this song louder or quieter on every Flaccy you sync with your Flaccy Server. A raised song is held back from clipping.")
    }
    static var reset: String { String(localized: "Reset to 0 dB") }
    static var louder: String { String(localized: "Louder by 0.5 dB") }
    static var quieter: String { String(localized: "Quieter by 0.5 dB") }
    static var songLouder: String { String(localized: "Song Louder") }
    static var songQuieter: String { String(localized: "Song Quieter") }

    static func level(_ tenths: Int) -> String {
        SongGain.label(tenths)
    }

    static func accessibilityLevel(_ tenths: Int) -> String {
        String(localized: "Song volume \(level(tenths))")
    }

    static func saveFailed(title: String) -> String {
        String(localized: "Couldn’t save the volume of “\(title)”. The library database refused the change, so the song keeps its previous level. Try again.")
    }
}
