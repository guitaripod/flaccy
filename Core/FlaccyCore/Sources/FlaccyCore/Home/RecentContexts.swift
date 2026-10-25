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
    /// Things the person took off Jump Back In, by key, with when. A play
    /// after that moment brings the thing back.
    public private(set) var dismissed: [String: Date]

    public init(entries: [Entry] = [], dismissed: [String: Date] = [:]) {
        self.entries = Array(entries.prefix(Self.capacity))
        self.dismissed = dismissed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            entries: try container.decode([Entry].self, forKey: .entries),
            dismissed: try container.decodeIfPresent([String: Date].self, forKey: .dismissed) ?? [:]
        )
    }

    /// Puts `context` first, dropping an older entry for the same thing and
    /// any dismissal of it. A plain queue names nothing to go back to and is
    /// ignored.
    public func recording(_ context: PlaybackContext, at date: Date) -> RecentContexts {
        guard context.kind != .queue else { return self }
        let rest = entries.filter { $0.context.key != context.key }
        var cleared = dismissed
        cleared.removeValue(forKey: context.key)
        return RecentContexts(entries: [Entry(context: context, playedAt: date)] + rest, dismissed: cleared)
    }

    /// Takes the thing off Jump Back In until it is played again.
    public func dismissing(key: String, at date: Date) -> RecentContexts {
        var updated = dismissed
        updated[key] = date
        return RecentContexts(entries: entries.filter { $0.context.key != key }, dismissed: updated)
    }
}

/// The Jump Back In shelf: what was recently started, merged with albums the
/// history shows were played before anything was recorded, newest first.
public enum JumpBackIn {

    /// Distinct contexts by `playedAt`, newest first (a recorded entry wins a
    /// tie with a history album), without the ones in `excluding` or played
    /// no later than their dismissal, at most `limit`.
    public static func pick(
        recents: [RecentContexts.Entry],
        history: [RecentContexts.Entry],
        excluding: Set<String>,
        dismissed: [String: Date] = [:],
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
            if let dismissedAt = dismissed[entry.context.key], entry.playedAt <= dismissedAt { continue }
            guard entry.context.kind != .queue, seen.insert(entry.context.key).inserted else { continue }
            picked.append(entry.context)
        }
        return picked
    }
}
