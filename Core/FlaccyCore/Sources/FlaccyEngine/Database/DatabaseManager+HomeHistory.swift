import Foundation
import GRDB

/// What Home asks of the history in one go: the windows the mixes count plays
/// in, how many recently played albums Jump Back In looks through, the On This
/// Day spans and the span This Week reads.
public struct HomeHistoryRequest: Sendable {
    public var now: Date
    public var tallyWindows: [Date]
    public var recentAlbumLimit: Int
    public var datedSince: Date
    public var onThisDaySpans: [DateInterval]
    public var weekSpan: DateInterval

    public init(
        now: Date,
        tallyWindows: [Date],
        recentAlbumLimit: Int,
        datedSince: Date,
        onThisDaySpans: [DateInterval],
        weekSpan: DateInterval
    ) {
        self.now = now
        self.tallyWindows = tallyWindows
        self.recentAlbumLimit = recentAlbumLimit
        self.datedSince = datedSince
        self.onThisDaySpans = onThisDaySpans
        self.weekSpan = weekSpan
    }
}

/// Everything Home reads from the history and the track index for one build.
public struct HomeHistoryRows: Sendable {
    public let readAt: Date
    public let hasLivePlays: Bool
    public let tallies: PlayTallies
    public let recentAlbums: [(albumTitle: String, artist: String, lastPlayed: Date)]
    public let dateAddedByPath: [String: Date]
    public let onThisDay: [ScrobbleRecord]
    public let week: [ScrobbleRecord]

    /// What a build falls back to when the read fails: no history at all.
    public static func nothing(at date: Date) -> HomeHistoryRows {
        HomeHistoryRows(
            readAt: date, hasLivePlays: false, tallies: PlayTallies(windowCount: 0),
            recentAlbums: [], dateAddedByPath: [:], onThisDay: [], week: []
        )
    }
}

extension DatabaseManager {

    /// Reads everything Home shows from the history in one transaction, so on
    /// a busy launch, with the scan and the history sync writing, Home waits
    /// for the database once instead of once per question.
    public func homeHistory(_ request: HomeHistoryRequest) throws -> HomeHistoryRows {
        try dbQueue.read { db in
            var onThisDay: [ScrobbleRecord] = []
            for span in request.onThisDaySpans {
                onThisDay += try Self.scrobbleRows(db, from: span.start, to: span.end)
            }
            return HomeHistoryRows(
                readAt: request.now,
                hasLivePlays: try Self.hasLivePlays(db),
                tallies: try Self.playTallies(db, since: request.tallyWindows, countingArtists: true),
                recentAlbums: try Self.recentlyPlayedAlbums(db, limit: request.recentAlbumLimit, since: request.datedSince),
                dateAddedByPath: Dictionary(
                    try Self.trackDateAddedByPath(db).map { ($0.path, $0.dateAdded) },
                    uniquingKeysWith: { first, _ in first }
                ),
                onThisDay: onThisDay,
                week: try Self.scrobbleRows(db, from: request.weekSpan.start, to: request.weekSpan.end)
            )
        }
    }
}
