import Foundation

/// Why a song's lyrics are not filled in word by word.
public enum LyricsTimingNoteKind: Sendable, Equatable {
    case lineByLine
    case unsynced
}

/// The reason, if there is one, a lyrics view should offer next to its timing
/// control. Mirrored in Rust as `linux/shared/src/lyrics/timing_note.rs`.
public enum LyricsTimingNote {

    /// None when the words are timed, the track is instrumental or there is
    /// nothing to read; otherwise the reason the fill is missing.
    public static func kind(for document: LyricsDocument) -> LyricsTimingNoteKind? {
        if document.instrumental || document.hasWordSync {
            return nil
        }
        if document.hasSynced {
            return .lineByLine
        }
        if document.plain != nil {
            return .unsynced
        }
        return nil
    }
}
