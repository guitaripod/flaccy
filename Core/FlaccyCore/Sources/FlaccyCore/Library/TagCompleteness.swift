import Foundation

/// Whether a file's own tags already say everything the AI cleanup exists to
/// work out: the song's title, its artist, its album and its place on the
/// album.
///
/// A folder whose every file passes is filed from its tags and never sent to
/// the model. The cleanup is for scrambled file names; on tags a person wrote
/// with care it spends an allowance and can only rewrite what was already
/// right. A placeholder a ripper writes when it knows nothing ("Unknown
/// Artist", "Track 03") is not a tag, and a file without a track number is not
/// complete, because the album would list it out of order.
public enum TagCompleteness {

    public static func isComplete(title: String?, artist: String?, albumTitle: String?, trackNumber: Int) -> Bool {
        guard trackNumber > 0 else { return false }
        guard let title = named(title), !isNumberedPlaceholder(title) else { return false }
        guard let artist = named(artist), artist != "unknown artist" else { return false }
        guard let albumTitle = named(albumTitle), albumTitle != "unknown album" else { return false }
        return true
    }

    /// The tag folded for comparison, or nil when it is missing or blank.
    private static func named(_ tag: String?) -> String? {
        guard let folded = tag?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !folded.isEmpty else {
            return nil
        }
        return folded
    }

    /// "Track 3", "track_03" or "Audiotrack 12": the title a ripper writes for
    /// a disc it could not look up.
    private static func isNumberedPlaceholder(_ foldedTitle: String) -> Bool {
        var rest = Substring(foldedTitle)
        if rest.hasPrefix("audio") { rest = rest.dropFirst("audio".count) }
        guard rest.hasPrefix("track") else { return false }
        rest = rest.dropFirst("track".count).drop { $0 == " " || $0 == "_" || $0 == "-" || $0 == "." }
        return !rest.isEmpty && rest.allSatisfy(\.isNumber)
    }
}
