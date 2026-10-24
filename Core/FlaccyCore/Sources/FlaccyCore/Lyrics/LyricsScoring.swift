import Foundation

/// What the player knows about the song it wants lyrics for.
public struct LyricsWanted: Sendable, Equatable {
    public var title: String
    public var artist: String
    public var album: String
    public var duration: Double

    public init(title: String, artist: String, album: String, duration: Double) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
    }
}

/// One record a lyrics server offered.
public struct LyricsCandidate: Sendable, Equatable {
    public var title: String
    public var artist: String
    public var album: String
    public var duration: Double
    public var hasSynced: Bool
    public var hasWordSync: Bool

    public init(
        title: String, artist: String, album: String, duration: Double,
        hasSynced: Bool, hasWordSync: Bool
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.hasSynced = hasSynced
        self.hasWordSync = hasWordSync
    }
}

/// Which lyrics record is the right one for a song. Mirrored in Rust as
/// `linux/shared/src/lyrics/score.rs` with the same weights.
public enum LyricsScoring {

    /// Two pressings of the same song can differ by a few seconds; beyond this
    /// the timings would be useless, so a candidate is rejected outright.
    public static let maxDurationDrift = 15.0

    /// Below this a candidate is a different song, not a near miss.
    public static let acceptedScore = 0.80

    /// Weighted similarity across the fields a server returns. Duration
    /// carries real weight because it is what distinguishes pressings whose
    /// timings differ, and a large drift disqualifies a candidate outright.
    /// Word timing is a tie-breaker: it never rescues a different song.
    public static func score(_ wanted: LyricsWanted, _ candidate: LyricsCandidate) -> Double? {
        let known = wanted.duration > 0.0 && candidate.duration > 0.0
        let drift = abs(wanted.duration - candidate.duration)
        if known && drift > maxDurationDrift {
            return nil
        }
        let durationScore = known ? 1.0 - min(drift / maxDurationDrift, 1.0) : 0.5
        let title = 0.35 * similarity(wanted.title, candidate.title)
        let artist = 0.30 * similarity(wanted.artist, candidate.artist)
        let duration = 0.25 * durationScore
        let synced = 0.06 * flag(candidate.hasSynced)
        let album = 0.04 * similarity(wanted.album, candidate.album)
        let words = 0.02 * flag(candidate.hasWordSync)
        return title + artist + duration + synced + album + words
    }

    /// Case- and punctuation-insensitive token overlap (Dice coefficient over
    /// words), enough to tell "Song (Remastered 2011)" from a different song.
    public static func similarity(_ left: String, _ right: String) -> Double {
        let leftTokens = tokens(left)
        let rightTokens = tokens(right)
        if leftTokens.isEmpty || rightTokens.isEmpty {
            return 0.0
        }
        let shared = leftTokens.filter { rightTokens.contains($0) }.count
        return 2.0 * Double(shared) / Double(leftTokens.count + rightTokens.count)
    }

    /// The index of the best candidate that clears `acceptedScore`, the first
    /// winning a tie.
    public static func bestCandidate(
        _ wanted: LyricsWanted, _ candidates: [LyricsCandidate]
    ) -> (index: Int, score: Double)? {
        var best: (index: Int, score: Double)?
        for (index, candidate) in candidates.enumerated() {
            guard let value = score(wanted, candidate) else { continue }
            if best == nil || value > best!.score {
                best = (index, value)
            }
        }
        guard let best, best.score >= acceptedScore else { return nil }
        return best
    }

    private static func flag(_ value: Bool) -> Double {
        value ? 1.0 : 0.0
    }

    private static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
