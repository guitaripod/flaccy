import Foundation

/// The words of the playlist pages on the iPhone, the iPad and the Mac, kept
/// in one place so the two clients say the same thing.
enum PlaylistCopy {

    /// "24 songs · 1 h 42 min", with how many songs the library no longer
    /// has when some are missing.
    static func summary(songs: Int, seconds: Double, missing: Int) -> String {
        guard songs > 0 else { return emptyTitle }
        var parts = [HomeCopy.songCount(songs)]
        if seconds > 0 { parts.append(HomeCopy.duration(seconds)) }
        if missing > 0 { parts.append(String(localized: "\(missing) missing")) }
        return parts.joined(separator: " · ")
    }

    static var emptyTitle: String { String(localized: "No Songs Yet") }
    static var emptyMessage: String { String(localized: "Add songs from your library, or pick from the suggestions under the list.") }
    static var addSongs: String { String(localized: "Add Songs") }
    static var addSongsMenu: String { String(localized: "Add Songs…") }
    static var missingSong: String { String(localized: "Not in your library") }

    static var renameTitle: String { String(localized: "Rename Playlist") }
    static var renameMenu: String { String(localized: "Rename…") }
    static var rename: String { String(localized: "Rename") }
    static var namePlaceholder: String { String(localized: "Playlist name") }
    static var duplicate: String { String(localized: "Duplicate") }
    static var copyWord: String { String(localized: "Copy") }
    static func duplicated(_ name: String) -> String { String(localized: "Made \u{201C}\(name)\u{201D}") }
    static var deleteMenu: String { String(localized: "Delete Playlist…") }
    static func deleteTitle(_ name: String) -> String { String(localized: "Delete \u{201C}\(name)\u{201D}?") }
    static var deleteMessage: String { String(localized: "Its songs stay in your library.") }
    static var delete: String { String(localized: "Delete") }

    static var removeFromPlaylist: String { String(localized: "Remove from Playlist") }
    static func removed(_ count: Int) -> String { String(localized: "Removed \(count) songs") }
    static func removedOne(_ title: String) -> String { String(localized: "Removed \u{201C}\(title)\u{201D}") }
    static var undo: String { String(localized: "Undo") }

    static func added(_ count: Int, to name: String) -> String {
        count == 1 ? String(localized: "Added to \(name)") : String(localized: "Added \(count) songs to \(name)")
    }
    static func alreadyIn(_ name: String) -> String { String(localized: "Already in \u{201C}\(name)\u{201D}") }
    static func addedSkipping(_ added: Int, skipped: Int, to name: String) -> String {
        String(localized: "Added \(added) songs to \(name) · \(skipped) already there")
    }
    static var inPlaylist: String { String(localized: "In this playlist") }

    static var suggestedTitle: String { String(localized: "Suggested Songs") }
    static var suggestedSubtitle: String { String(localized: "From your library, never added on their own") }
    static var refresh: String { String(localized: "Refresh") }
    static var hideSuggestions: String { String(localized: "Hide Suggested Songs") }
    static var showSuggestions: String { String(localized: "Show Suggested Songs") }
    static func addSuggestion(_ title: String) -> String { String(localized: "Add \(title) to the playlist") }

    static var sortBy: String { String(localized: "Sort By") }
    static func sortedBy(_ order: String) -> String { String(localized: "Sorted by \(order)") }
    static var backToPlaylistOrder: String { String(localized: "Returns to Playlist Order") }

    static var select: String { String(localized: "Select") }
    static var selectAll: String { String(localized: "Select All") }
    static var deselectAll: String { String(localized: "Deselect All") }
    static func selected(_ count: Int) -> String { String(localized: "\(count) selected") }
    static var searchPlaceholder: String { String(localized: "Find in Playlist") }

    static func writeFailed(_ name: String) -> String {
        String(localized: "Couldn't change \u{201C}\(name)\u{201D} — the library database couldn't be written. Check free disk space and try again.")
    }
}
