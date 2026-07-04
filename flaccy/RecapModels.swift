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

/// One-time backfill state for the "Import Last.fm history" affordance. The
/// associated counts carry live import progress (`importing`) and the final
/// summary (`done`) so the banner can communicate how many scrobbles landed.
enum RecapImportState: Hashable {
    case available
    case importing(imported: Int)
    case done(imported: Int)
    case unavailable

    var isImporting: Bool { if case .importing = self { true } else { false } }
    var isDone: Bool { if case .done = self { true } else { false } }

    /// Whether the import banner should remain on screen. A freshly-completed
    /// import keeps its "Imported N scrobbles" summary; a persisted-done state
    /// restored on a later launch (`imported == 0`) hides the banner entirely,
    /// as does `unavailable` — without a Last.fm account the Recap is purely
    /// local and shows no Last.fm chrome.
    var showsBanner: Bool {
        switch self {
        case .done(let imported): return imported > 0
        case .unavailable: return false
        case .available, .importing: return true
        }
    }
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
    var artworkTitle: String?
    var artworkArtist: String?
    var isLocal: Bool = false
}

nonisolated struct AlbumItem: Hashable, Sendable {
    let rank: Int
    let name: String
    let artist: String
    let playCount: Int
    let imageURL: String?
    var artworkTitle: String?
    var artworkArtist: String?
    var isLocal: Bool = false
    var localAlbumID: String?
}

nonisolated struct TrackItem: Hashable, Sendable {
    let rank: Int
    let name: String
    let artist: String
    let playCount: Int
    var artworkTitle: String?
    var artworkArtist: String?
    var isLocal: Bool = false
    var localTrackID: URL?
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

/// A case- and punctuation-insensitive index over the local library, used to
/// resolve Last.fm chart entries (whose casing/formatting often differs from the
/// AI-cleaned local metadata) back to the real owned album/track. This is what
/// lets the Recap show local cover art and enable tap-to-play for owned music.
nonisolated struct RecapLibraryIndex {
    private let albumsByKey: [String: Album]
    private let tracksByKey: [String: Track]
    private let albumByArtist: [String: Album]

    init(albums: [Album] = [], tracks: [Track] = []) {
        var albumMap: [String: Album] = [:]
        var artistMap: [String: Album] = [:]
        for album in albums {
            albumMap[Self.key(album.title, album.artist)] = album
            let artistKey = Self.normalize(album.artist)
            if !artistKey.isEmpty, artistMap[artistKey] == nil { artistMap[artistKey] = album }
        }
        var trackMap: [String: Track] = [:]
        for track in tracks { trackMap[Self.key(track.title, track.artist)] = track }
        albumsByKey = albumMap
        tracksByKey = trackMap
        albumByArtist = artistMap
    }

    func album(name: String, artist: String) -> Album? { albumsByKey[Self.key(name, artist)] }
    func track(title: String, artist: String) -> Track? { tracksByKey[Self.key(title, artist)] }
    func representativeAlbum(forArtist artist: String) -> Album? { albumByArtist[Self.normalize(artist)] }

    private static func key(_ a: String, _ b: String) -> String {
        normalize(a) + "\u{0}" + normalize(b)
    }

    private static func normalize(_ value: String) -> String {
        let folded = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        var result = String.UnicodeScalarView()
        for scalar in folded.unicodeScalars where CharacterSet.alphanumerics.contains(scalar) {
            result.append(scalar)
        }
        return String(result)
    }
}
