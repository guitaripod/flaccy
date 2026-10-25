import FlaccyCore
import Foundation

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
    var calendarHeatmap: [Date: Int]? = nil
    var previousPlays: Int? = nil
    var previousMinutes: Int? = nil
    var previousSpanDays: Int? = nil

    var hasScrobbles: Bool { totalPlays > 0 }

    /// Whether there is anything worth showing — local plays, or top lists
    /// backfilled from Last.fm's network charts when local scrobbles are sparse.
    var hasContent: Bool { hasScrobbles || !topArtists.isEmpty || !topTracks.isEmpty || !topAlbums.isEmpty }
}

/// Diffable sections, one per dashboard row-group.
nonisolated enum RecapSection: Int, Hashable, CaseIterable {
    case profile
    case syncBanner
    case period
    case artists
    case albums
    case tracks
    case clock
    case streak
    case persona

    var headerTitle: String? {
        switch self {
        case .artists: String(localized: "Top Artists")
        case .albums: String(localized: "Top Albums")
        case .tracks: String(localized: "Top Tracks")
        case .clock: String(localized: "Listening Clock")
        case .streak: String(localized: "Your Streak")
        case .persona: String(localized: "Your Persona")
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
    case syncBanner(ListenHistoryStatus)
    case period(ChartPeriod)
    case artist(RecapArtistItem)
    case album(AlbumItem)
    case track(TrackItem)
    case clock(ClockItem)
    case streak(StreakItem)
    case persona(PersonaItem)
}

/// A short, warm blurb shown under each persona label.
///
/// The persona itself is a stable English identifier produced by the stats services and used as a
/// lookup key here, so every screen must render `title(for:)` rather than the raw value.
nonisolated enum RecapPersona {
    static func title(for persona: String) -> String {
        switch persona {
        case "Night Owl": String(localized: "Night Owl")
        case "Explorer": String(localized: "Explorer")
        case "Loyalist": String(localized: "Loyalist")
        case "Devotee": String(localized: "Devotee")
        default: String(localized: "Newcomer")
        }
    }

    static func blurb(for persona: String) -> String {
        switch persona {
        case "Night Owl": String(localized: "You do your best listening after dark.")
        case "Explorer": String(localized: "Always chasing the next new sound.")
        case "Loyalist": String(localized: "A handful of artists own your heart.")
        case "Devotee": String(localized: "Deep, steady devotion to your favorites.")
        default: String(localized: "Your story is just getting started.")
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
    private let albums: [Album]

    init(albums: [Album] = [], tracks: [Track] = []) {
        self.albums = albums
        var albumMap: [String: Album] = [:]
        var artistMap: [String: Album] = [:]
        for album in albums {
            albumMap[Self.albumKey(album.title, album.artist)] = album
            let artistKey = ListenHistory.artistKey(album.artist)
            if !artistKey.isEmpty, artistMap[artistKey] == nil { artistMap[artistKey] = album }
        }
        var trackMap: [String: Track] = [:]
        for track in tracks { trackMap[ListenHistory.trackKey(title: track.title, artist: track.artist)] = track }
        albumsByKey = albumMap
        tracksByKey = trackMap
        albumByArtist = artistMap
    }

    func album(name: String, artist: String) -> Album? { albumsByKey[Self.albumKey(name, artist)] }
    func track(title: String, artist: String) -> Track? { tracksByKey[ListenHistory.trackKey(title: title, artist: artist)] }
    func representativeAlbum(forArtist artist: String) -> Album? { albumByArtist[ListenHistory.artistKey(artist)] }

    /// The owned songs behind a top-tracks chart, in rank order. Entries the
    /// library does not hold are skipped, so the queue is whatever can play.
    func queue(forTracks chart: [ChartTrack]) -> [Track] {
        Self.unique(chart.compactMap { track(title: $0.name, artist: $0.artistName) })
    }

    /// The owned releases behind a top-albums chart, in rank order, each one
    /// whole and in its own track order.
    func queue(forAlbums chart: [ChartAlbum]) -> [Track] {
        Self.unique(chart.flatMap { album(name: $0.name, artist: $0.artistName)?.tracks ?? [] })
    }

    /// Everything the library holds by each charted artist, in rank order.
    func queue(forArtists chart: [ChartArtist]) -> [Track] {
        Self.unique(chart.flatMap { tracks(byArtist: $0.name) })
    }

    /// Every owned track `artist` is on: the releases credited to them in full
    /// plus the individual tracks they perform on somebody else's record, so a
    /// composer on a Various Artists soundtrack is not an empty queue. Mirrors
    /// `Core::artist_tracks` on Linux and `ownedTracks()` on the artist pages.
    func tracks(byArtist artist: String) -> [Track] {
        let key = LibraryHygiene.artistKey(artist)
        return albums.flatMap { album -> [Track] in
            if LibraryHygiene.artistKey(album.artist) == key { return album.tracks }
            return album.tracks.filter { LibraryHygiene.artistKey($0.artist) == key }
        }
    }

    private static func unique(_ tracks: [Track]) -> [Track] {
        var seen = Set<URL>()
        return tracks.filter { seen.insert($0.fileURL).inserted }
    }

    private static func albumKey(_ title: String, _ artist: String) -> String {
        ListenHistory.albumKey(title) + "\u{0}" + ListenHistory.artistKey(artist)
    }
}
