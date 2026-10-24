import FlaccyCore
import Foundation

/// The words behind the chip a lyrics view shows when a song's lyrics are not
/// filled in word by word, shared by iOS and macOS so both explain it the same
/// way. The Linux client carries the same text in `timing_note.rs`.
enum LyricsTimingNoteCopy {

    /// The two words on the chip itself.
    static func label(for kind: LyricsTimingNoteKind) -> String {
        switch kind {
        case .lineByLine:
            return String(localized: "Line by line")
        case .unsynced:
            return String(localized: "Not timed")
        }
    }

    static func title(for kind: LyricsTimingNoteKind) -> String {
        switch kind {
        case .lineByLine:
            return String(localized: "Timed line by line")
        case .unsynced:
            return String(localized: "These lyrics aren't timed")
        }
    }

    static func body(for kind: LyricsTimingNoteKind) -> String {
        switch kind {
        case .lineByLine:
            return String(localized: "This song's lyrics are timed one line at a time, so Flaccy lights the line being sung but can't fill it word by word. Word timing is still rare: it comes from lrclib when a contributor adds it, or from an enhanced .elrc file saved next to the song.")
        case .unsynced:
            return String(localized: "This song has lyrics but no timing, so they can't follow the music. Timing comes from lrclib when a contributor adds it, or from a .lrc or .elrc file saved next to the song.")
        }
    }

    static var accessibilityHint: String {
        String(localized: "Explains how this song's lyrics are timed")
    }
}
