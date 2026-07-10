#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Immutable snapshot of one calendar year of listening, computed entirely from
/// local scrobbles so the Year in Music works offline.
nonisolated struct YearInMusicData: Sendable {
    let year: Int
    let totalPlays: Int
    let totalMinutes: Int
    let distinctArtists: Int
    let distinctAlbums: Int
    let distinctTracks: Int
    let topArtists: [ChartArtist]
    let topAlbums: [ChartAlbum]
    let topTracks: [ChartTrack]
    let peakDay: Date?
    let peakDayPlays: Int
    let peakHour: Int?
    let longestStreak: Int
    let persona: String
    let artistTopAlbums: [String: String]
    let trackAlbums: [String: String]

    var hasContent: Bool { totalPlays > 0 }
}

/// The individual story pages the share configurator offers.
nonisolated enum StorySlide: Int, CaseIterable, Sendable {
    case overview
    case artists
    case tracks
    case numbers
    case poster

    var displayName: String {
        switch self {
        case .overview: "Overview"
        case .artists: "Top Artists"
        case .tracks: "Top Tracks"
        case .numbers: "The Numbers"
        case .poster: "Poster"
        }
    }
}

/// Export aspect: 9:16 fills Instagram Stories; 4:5 is the largest uncropped
/// aspect for Instagram feed posts and reads far better in X's timeline grid.
nonisolated enum StoryFormat: Sendable {
    case story
    case post

    var canvasSize: CGSize {
        switch self {
        case .story: CGSize(width: 360, height: 640)
        case .post: CGSize(width: 360, height: 450)
        }
    }
}

/// A named gradient + accent the user can pick in the share configurator.
struct StoryTheme: Equatable {
    let name: String
    let gradientColors: [PlatformColor]
    let accent: PlatformColor

    /// The selectable themes; the first is derived from the user's own listening
    /// palette so every library gets a signature look.
    static func all(seedPalette: ArtworkPalette) -> [StoryTheme] {
        let first = seedPalette.colors.first ?? .systemIndigo
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        #if canImport(UIKit)
        first.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        #else
        let rgb = first.usingColorSpace(.deviceRGB) ?? first
        rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        #endif
        let neighborHue = (hue + 0.09).truncatingRemainder(dividingBy: 1)
        let aurora = StoryTheme(
            name: "Aurora",
            gradientColors: [
                PlatformColor(hue: hue, saturation: max(0.45, saturation * 0.9), brightness: 0.32, alpha: 1),
                PlatformColor(hue: neighborHue, saturation: max(0.4, saturation * 0.8), brightness: 0.18, alpha: 1),
                .black,
            ],
            accent: PlatformColor(hue: hue, saturation: min(1, max(0.5, saturation * 0.85)), brightness: 0.9, alpha: 1)
        )
        return [
            aurora,
            StoryTheme(
                name: "Sunset",
                gradientColors: [
                    PlatformColor(red: 0.55, green: 0.12, blue: 0.25, alpha: 1),
                    PlatformColor(red: 0.35, green: 0.08, blue: 0.35, alpha: 1),
                    .black,
                ],
                accent: PlatformColor(red: 1, green: 0.55, blue: 0.4, alpha: 1)
            ),
            StoryTheme(
                name: "Ocean",
                gradientColors: [
                    PlatformColor(red: 0.02, green: 0.25, blue: 0.38, alpha: 1),
                    PlatformColor(red: 0.03, green: 0.12, blue: 0.3, alpha: 1),
                    .black,
                ],
                accent: PlatformColor(red: 0.35, green: 0.85, blue: 0.9, alpha: 1)
            ),
            StoryTheme(
                name: "Orchid",
                gradientColors: [
                    PlatformColor(red: 0.35, green: 0.1, blue: 0.5, alpha: 1),
                    PlatformColor(red: 0.15, green: 0.05, blue: 0.3, alpha: 1),
                    .black,
                ],
                accent: PlatformColor(red: 0.85, green: 0.55, blue: 1, alpha: 1)
            ),
            StoryTheme(
                name: "Noir",
                gradientColors: [
                    PlatformColor(white: 0.16, alpha: 1),
                    PlatformColor(white: 0.06, alpha: 1),
                    .black,
                ],
                accent: .white
            ),
        ]
    }

}

/// Cover art resolved up front for a `YearInMusicData`, so the story renderer
/// itself stays a pure layout function.
/// Cover art resolved up front for a `YearInMusicData`. Scrobble metadata often
/// differs in casing/punctuation from the local library, so every lookup falls
/// through exact DB matches to the fuzzy `RecapLibraryIndex`, and finally to a
/// representative album by the same artist — maximizing how many tiles get real
/// art before the renderer reaches for monogram fallbacks.
struct StoryArtwork {
    let collage: [PlatformImage?]
    let artistRows: [PlatformImage?]
    let trackRows: [PlatformImage?]

    var artistHero: PlatformImage? { artistRows.first ?? nil }
    var trackHero: PlatformImage? { trackRows.first ?? nil }

    static let empty = StoryArtwork(collage: [], artistRows: [], trackRows: [])

    static func resolve(for data: YearInMusicData) -> StoryArtwork {
        let index = RecapLibraryIndex(albums: Library.shared.albums, tracks: Library.shared.allTracks)

        func exactAlbumImage(title: String, artist: String) -> PlatformImage? {
            if let cached = AlbumArtworkCache.shared.artwork(forAlbum: title, artist: artist) {
                return cached
            }
            if let data = try? DatabaseManager.shared.fetchAlbumArtwork(title: title, artist: artist) {
                return PlatformImage(data: data)
            }
            return nil
        }

        func artForArtist(_ artist: String) -> PlatformImage? {
            if let album = index.representativeAlbum(forArtist: artist) {
                if let art = album.artwork ?? exactAlbumImage(title: album.title, artist: album.artist) { return art }
            }
            if let albumTitle = data.artistTopAlbums[artist] {
                return exactAlbumImage(title: albumTitle, artist: artist)
            }
            return nil
        }

        func artForAlbum(name: String, artist: String) -> PlatformImage? {
            if let exact = exactAlbumImage(title: name, artist: artist) { return exact }
            if let album = index.album(name: name, artist: artist) {
                if let art = album.artwork ?? exactAlbumImage(title: album.title, artist: album.artist) { return art }
            }
            return artForArtist(artist)
        }

        func artForTrack(title: String, artist: String) -> PlatformImage? {
            if let track = index.track(title: title, artist: artist) {
                if let art = track.artwork ?? exactAlbumImage(title: track.albumTitle, artist: track.artist) { return art }
            }
            if let albumTitle = data.trackAlbums["\(title)\u{0}\(artist)"],
               let art = exactAlbumImage(title: albumTitle, artist: artist) {
                return art
            }
            return artForArtist(artist)
        }

        return StoryArtwork(
            collage: data.topAlbums.prefix(4).map { artForAlbum(name: $0.name, artist: $0.artistName) },
            artistRows: data.topArtists.map { artForArtist($0.name) },
            trackRows: data.topTracks.map { artForTrack(title: $0.name, artist: $0.artistName) }
        )
    }
}
