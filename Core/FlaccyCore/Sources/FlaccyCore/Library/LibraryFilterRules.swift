import Foundation

/// The ordering and membership rules behind the Songs and Albums filter chips,
/// shared so every client answers "what is recent" the same way. Everything is
/// pure: `now` is injected, ids are opaque, and each function returns the
/// ordered ids the caller then resolves back to its own rows. Mirrored in Rust
/// as `linux/shared/src/library_filter_rules.rs`.
public enum LibraryFilterRules {

    public struct Thresholds: Sendable, Equatable {
        public let minimum: Int
        public let fallback: Int

        public init(minimum: Int, fallback: Int) {
            self.minimum = minimum
            self.fallback = fallback
        }

        public static let songs = Thresholds(minimum: 10, fallback: 40)
        public static let albums = Thresholds(minimum: 6, fallback: 24)
    }

    public static let recentWindow: TimeInterval = 30 * 86_400
    public static let rediscoverMinimumDays = 14
    public static let rediscoverMinimumPlays = 2

    /// Newest first. Everything added inside the recent window when there are
    /// at least `minimum` such entries, otherwise the newest `fallback` of the
    /// whole library, so a quiet month never leaves the chip empty.
    public static func recentlyAdded(
        _ entries: [(id: String, dateAdded: Date)],
        now: Date,
        thresholds: Thresholds
    ) -> [String] {
        let sorted = newestFirst(entries.map { (id: $0.id, date: $0.dateAdded) })
        let recent = withinWindow(sorted, now: now)
        return recent.count >= thresholds.minimum
            ? recent.map(\.id)
            : sorted.prefix(thresholds.fallback).map(\.id)
    }

    /// Most recently played first, never-played entries dropped. Falls back to
    /// every played entry (uncapped) when the recent window is too thin.
    public static func recentlyPlayed(
        _ entries: [(id: String, lastPlayed: Date?)],
        now: Date,
        thresholds: Thresholds
    ) -> [String] {
        let played = entries.compactMap { entry in entry.lastPlayed.map { (id: entry.id, date: $0) } }
        let sorted = newestFirst(played)
        let recent = withinWindow(sorted, now: now)
        return recent.count >= thresholds.minimum ? recent.map(\.id) : sorted.map(\.id)
    }

    /// Heavily played but neglected: at least two plays and fourteen whole days
    /// of silence, ranked by plays per day since (plus one) so a long-ignored
    /// favourite outranks a barely-qualifying one. Ties break by id.
    public static func rediscover(
        _ entries: [(id: String, plays: Int, lastPlayed: Date?)],
        now: Date
    ) -> [String] {
        var scored: [(id: String, score: Double)] = []
        for entry in entries {
            guard let lastPlayed = entry.lastPlayed else { continue }
            let days = Int((now.timeIntervalSince(lastPlayed) / 86_400).rounded(.down))
            guard days >= rediscoverMinimumDays, entry.plays >= rediscoverMinimumPlays else { continue }
            scored.append((id: entry.id, score: Double(entry.plays) / Double(days + 1)))
        }
        scored.sort { lhs, rhs in
            lhs.score != rhs.score ? lhs.score > rhs.score : lhs.id < rhs.id
        }
        return scored.map(\.id)
    }

    /// Most plays first, unplayed entries dropped. Equal counts go to the more
    /// recently played (never-played last), then by title.
    public static func mostPlayed(
        _ entries: [(id: String, plays: Int, lastPlayed: Date?, title: String)]
    ) -> [String] {
        entries
            .filter { $0.plays > 0 }
            .sorted { lhs, rhs in
                if lhs.plays != rhs.plays { return lhs.plays > rhs.plays }
                if lhs.lastPlayed != rhs.lastPlayed { return isLater(lhs.lastPlayed, than: rhs.lastPlayed) }
                return titleOrders(lhs.title, before: rhs.title)
            }
            .map(\.id)
    }

    private static func newestFirst(_ entries: [(id: String, date: Date)]) -> [(id: String, date: Date)] {
        entries.enumerated()
            .sorted { lhs, rhs in
                lhs.element.date != rhs.element.date
                    ? lhs.element.date > rhs.element.date
                    : lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private static func withinWindow(_ sorted: [(id: String, date: Date)], now: Date) -> [(id: String, date: Date)] {
        let cutoff = now.addingTimeInterval(-recentWindow)
        return sorted.filter { $0.date >= cutoff }
    }

    private static func isLater(_ lhs: Date?, than rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case let (l?, r?): l > r
        case (.some, .none): true
        default: false
        }
    }

    private static func titleOrders(_ lhs: String, before rhs: String) -> Bool {
        let foldedLeft = lhs.lowercased()
        let foldedRight = rhs.lowercased()
        return foldedLeft != foldedRight ? foldedLeft < foldedRight : lhs < rhs
    }
}
