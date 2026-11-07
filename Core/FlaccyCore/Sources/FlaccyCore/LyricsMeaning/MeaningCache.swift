import Foundation

/// Which stored readings still answer. Mirrored in Rust as
/// `linux/shared/src/meaning/cache.rs`.
public enum MeaningCache {

    /// The stored row that holds a song's Wikipedia story, or an empty body
    /// for "Wikipedia has no article about it".
    public static let storyScope = "wikipedia"
    /// The stored row that holds the model's reading of the whole song.
    public static let songScope = "song"
    /// How long a found story and a miss are believed before Wikipedia is
    /// asked again. A reading the model wrote never goes stale: asking again
    /// would cost a request and give a different wording of the same thing.
    public static let storyStaleDays = 90.0
    public static let storyMissDays = 30.0

    /// The stored row for one line's reading. A chorus sung four times is one
    /// question, whatever its case or spacing.
    public static func lineScope(_ text: String) -> String {
        let folded = text.lowercased()
            .unicodeScalars
            .split(omittingEmptySubsequences: true, whereSeparator: LyricsText.isWhitespace)
            .map { LyricsText.string($0) }
            .joined(separator: " ")
        return "line:\(folded)"
    }

    /// Whether a stored row still answers, by its scope, whether it holds
    /// anything and how many days old it is.
    public static func isFresh(scope: String, hasBody: Bool, ageDays: Double) -> Bool {
        guard scope == storyScope else { return hasBody }
        return ageDays < (hasBody ? storyStaleDays : storyMissDays)
    }
}
