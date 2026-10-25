import Foundation

/// The albums, playlists, mixes and radios the person started, newest first,
/// so Jump Back In can offer the things themselves rather than single songs.
public struct RecentContexts: Codable, Equatable, Sendable {

    public struct Entry: Codable, Equatable, Sendable {
        public var context: PlaybackContext
        public var playedAt: Date

        public init(context: PlaybackContext, playedAt: Date) {
            self.context = context
            self.playedAt = playedAt
        }
    }

    public static let capacity = 24

    public private(set) var entries: [Entry]

    public init(entries: [Entry] = []) {
        self.entries = Array(entries.prefix(Self.capacity))
    }

    /// Puts `context` first, dropping an older entry for the same thing. A
    /// plain queue names nothing to go back to and is ignored.
    public func recording(_ context: PlaybackContext, at date: Date) -> RecentContexts {
        guard context.kind != .queue else { return self }
        let rest = entries.filter { $0.context.key != context.key }
        return RecentContexts(entries: [Entry(context: context, playedAt: date)] + rest)
    }

    public func removing(key: String) -> RecentContexts {
        RecentContexts(entries: entries.filter { $0.context.key != key })
    }
}

/// The Jump Back In shelf: what was recently started, merged with albums the
/// history shows were played before anything was recorded, newest first.
public enum JumpBackIn {

    /// Distinct contexts by `playedAt`, newest first (a recorded entry wins a
    /// tie with a history album), without the ones in `excluding`, at most
    /// `limit`.
    public static func pick(
        recents: [RecentContexts.Entry],
        history: [RecentContexts.Entry],
        excluding: Set<String>,
        limit: Int = HomeComposer.jumpBackInLimit
    ) -> [PlaybackContext] {
        let merged = (recents.map { ($0, 0) } + history.map { ($0, 1) })
            .enumerated()
            .sorted { lhs, rhs in
                let (left, right) = (lhs.element, rhs.element)
                if left.0.playedAt != right.0.playedAt { return left.0.playedAt > right.0.playedAt }
                if left.1 != right.1 { return left.1 < right.1 }
                return lhs.offset < rhs.offset
            }
        var seen = excluding
        var picked: [PlaybackContext] = []
        for (entry, _) in merged.map(\.element) where picked.count < limit {
            guard entry.context.kind != .queue, seen.insert(entry.context.key).inserted else { continue }
            picked.append(entry.context)
        }
        return picked
    }
}
