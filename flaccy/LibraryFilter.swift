import Foundation

/// A quick pivot applied live to the current Albums/Songs segment, surfaced as a
/// row of glass capsule chips beneath the navigation bar and persisted across
/// launches. All filters read local state only (DB codec/date/loved columns and
/// scrobble stats), so they work offline.
nonisolated enum LibraryFilter: String, CaseIterable, Sendable {
    case all
    case lossless
    case recentlyAdded
    case recentlyPlayed
    case favorites
    case rediscover

    private static let storageKey = "libraryFilter"

    static var persisted: LibraryFilter {
        LibraryFilter(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .all
    }

    func persist() {
        UserDefaults.standard.set(rawValue, forKey: Self.storageKey)
    }

    var displayName: String {
        switch self {
        case .all: "All"
        case .lossless: "Lossless"
        case .recentlyAdded: "Recently Added"
        case .recentlyPlayed: "Recently Played"
        case .favorites: "Favorites"
        case .rediscover: "Rediscover"
        }
    }

    var icon: String {
        switch self {
        case .all: "square.stack"
        case .lossless: "waveform.badge.magnifyingglass"
        case .recentlyAdded: "clock.badge.plus"
        case .recentlyPlayed: "clock.arrow.circlepath"
        case .favorites: "heart.fill"
        case .rediscover: "sparkle.magnifyingglass"
        }
    }

    /// Whether this chip is offered for the given segment. Rediscover is
    /// album-driven; the pivots are meaningless for artists and playlists.
    func isAvailable(in segment: LibraryViewModel.Segment) -> Bool {
        switch segment {
        case .albums, .songs:
            return true
        case .artists, .playlists:
            return self == .all
        }
    }
}
