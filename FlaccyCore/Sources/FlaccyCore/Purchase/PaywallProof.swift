import Foundation

/// What the paywall can honestly say the reader has already set up: a live
/// snapshot of COUNT queries over the library, never the frozen `libraryDebut`
/// row, so it keeps growing after the showpiece has played.
public struct PaywallProof: Equatable, Sendable {
    public var trackCount: Int
    public var losslessTrackCount: Int
    public var totalDurationSeconds: Double
    public var plays: Int
    public var playsAreScrobbled: Bool
    public var lyricsMatched: Int
    public var coversResolved: Int
    public var aiReviewedTracks: Int

    public init(
        trackCount: Int,
        losslessTrackCount: Int,
        totalDurationSeconds: Double,
        plays: Int,
        playsAreScrobbled: Bool,
        lyricsMatched: Int,
        coversResolved: Int,
        aiReviewedTracks: Int
    ) {
        self.trackCount = trackCount
        self.losslessTrackCount = losslessTrackCount
        self.totalDurationSeconds = totalDurationSeconds
        self.plays = plays
        self.playsAreScrobbled = playsAreScrobbled
        self.lyricsMatched = lyricsMatched
        self.coversResolved = coversResolved
        self.aiReviewedTracks = aiReviewedTracks
    }

    public static let empty = PaywallProof(
        trackCount: 0,
        losslessTrackCount: 0,
        totalDurationSeconds: 0,
        plays: 0,
        playsAreScrobbled: false,
        lyricsMatched: 0,
        coversResolved: 0,
        aiReviewedTracks: 0
    )

    public var hasLibrary: Bool { trackCount > 0 }

    /// Whole hours of music in the library, floored; a total that is not a
    /// finite positive number reads as none rather than trapping.
    public var listeningHours: Int {
        guard totalDurationSeconds.isFinite, totalDurationSeconds > 0 else { return 0 }
        return Int(totalDurationSeconds / 3600)
    }

    public enum Line: Equatable, Sendable {
        case lossless(tracks: Int, hours: Int)
        case scrobbled(Int)
        case playsCounted(Int)
        case lyrics(Int)
        case covers(Int)
        case aiReviewed(Int)
    }

    /// Priority: lossless (when losslessTrackCount > 0) → plays (scrobbled or counted, > 0) → lyrics → covers → aiReviewed; zeros skipped; at most `limit`.
    public func lines(limit: Int = 3) -> [Line] {
        var lines: [Line] = []
        if losslessTrackCount > 0 {
            lines.append(.lossless(tracks: losslessTrackCount, hours: listeningHours))
        }
        if plays > 0 {
            lines.append(playsAreScrobbled ? .scrobbled(plays) : .playsCounted(plays))
        }
        if lyricsMatched > 0 { lines.append(.lyrics(lyricsMatched)) }
        if coversResolved > 0 { lines.append(.covers(coversResolved)) }
        if aiReviewedTracks > 0 { lines.append(.aiReviewed(aiReviewedTracks)) }
        return Array(lines.prefix(max(0, limit)))
    }
}
