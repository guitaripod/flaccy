import UIKit

/// The immutable snapshot the Recap dashboard renders. Computed off the main
/// thread from local scrobbles (plus an optional Last.fm profile) so it always
/// has something to show offline.
nonisolated struct RecapData: Sendable {
    var userInfo: LastFMUserInfo?
    var period: ChartPeriod
    var totalPlays: Int
    var totalMinutes: Int
    var topArtists: [ChartArtist]
    var topAlbums: [ChartAlbum]
    var topTracks: [ChartTrack]
    var listeningClock: [Int]
    var streak: Int
    var heatmap: [Date: Int]
    var persona: String

    var hasScrobbles: Bool { totalPlays > 0 }

    /// Whether there is anything worth showing — local plays, or top lists
    /// backfilled from Last.fm's network charts when local scrobbles are sparse.
    var hasContent: Bool { hasScrobbles || !topArtists.isEmpty || !topTracks.isEmpty || !topAlbums.isEmpty }
}

/// One-time backfill state for the "Import Last.fm history" affordance.
enum RecapImportState: Hashable {
    case available
    case importing
    case done
    case unavailable
}

/// Diffable sections, one per dashboard row-group.
nonisolated enum RecapSection: Int, Hashable, CaseIterable {
    case profile
    case importBanner
    case period
    case artists
    case albums
    case tracks
    case clock
    case streak
    case persona

    var headerTitle: String? {
        switch self {
        case .artists: "Top Artists"
        case .albums: "Top Albums"
        case .tracks: "Top Tracks"
        case .clock: "Listening Clock"
        case .streak: "Your Streak"
        case .persona: "Your Persona"
        default: nil
        }
    }
}

/// Value-type payloads for diffable items; every field participates in equality
/// so a changed stat naturally re-renders its cell.
nonisolated struct ProfileItem: Hashable, Sendable {
    let username: String
    let sinceText: String?
    let avatarURL: String?
    let totalPlays: Int
    let totalMinutes: Int
}

nonisolated struct RecapArtistItem: Hashable, Sendable {
    let rank: Int
    let name: String
    let playCount: Int
}

nonisolated struct AlbumItem: Hashable, Sendable {
    let rank: Int
    let name: String
    let artist: String
    let playCount: Int
    let imageURL: String?
}

nonisolated struct TrackItem: Hashable, Sendable {
    let rank: Int
    let name: String
    let artist: String
    let playCount: Int
}

nonisolated struct ClockItem: Hashable, Sendable {
    let buckets: [Int]
    let seed: String
}

nonisolated struct StreakItem: Hashable, Sendable {
    let streakDays: Int
    let days: [HeatmapDay]
    let seed: String

    var heatmap: [Date: Int] { Dictionary(days.map { ($0.date, $0.count) }, uniquingKeysWith: { a, _ in a }) }
}

nonisolated struct HeatmapDay: Hashable, Sendable {
    let date: Date
    let count: Int
}

nonisolated struct PersonaItem: Hashable, Sendable {
    let persona: String
    let seed: String
}

/// Heterogeneous diffable item; equality drives per-cell reconfiguration.
nonisolated enum RecapItem: Hashable {
    case profile(ProfileItem)
    case importBanner(RecapImportState)
    case period(ChartPeriod)
    case artist(RecapArtistItem)
    case album(AlbumItem)
    case track(TrackItem)
    case clock(ClockItem)
    case streak(StreakItem)
    case persona(PersonaItem)
}

/// A short, warm blurb shown under each persona label.
enum RecapPersona {
    static func blurb(for persona: String) -> String {
        switch persona {
        case "Night Owl": "You do your best listening after dark."
        case "Explorer": "Always chasing the next new sound."
        case "Loyalist": "A handful of artists own your heart."
        case "Devotee": "Deep, steady devotion to your favorites."
        default: "Your story is just getting started."
        }
    }

    static func symbol(for persona: String) -> String {
        switch persona {
        case "Night Owl": "moon.stars.fill"
        case "Explorer": "safari.fill"
        case "Loyalist": "heart.fill"
        case "Devotee": "flame.fill"
        default: "sparkles"
        }
    }
}
