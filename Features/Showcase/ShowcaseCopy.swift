import Foundation

/// One thing Flaccy can do, as the showcase tells it: a symbol, its name and one line about it.
nonisolated struct ShowcaseFeature: Equatable, Sendable {
    let id: String
    let symbol: String
    let title: String
    let detail: String
}

/// A named group of features on the showcase's second page.
nonisolated struct ShowcaseSection: Equatable, Sendable {
    let id: String
    let title: String
    let features: [ShowcaseFeature]
}

/// The words of the 2.0 showcase: the four things its first page leads with and everything its second page lists.
nonisolated enum ShowcaseCopy {

    static let name = "Flaccy"
    static let version = "2.0"

    static var tagline: String { String(localized: "The player for the music you own.") }
    static var seeEverything: String { String(localized: "See Everything Flaccy Can Do") }
    static var everythingTitle: String { String(localized: "Everything Flaccy Can Do") }
    static var proceed: String { String(localized: "Start Listening") }
    static var back: String { String(localized: "Back") }
    static var seePlans: String { String(localized: "See Plans") }
    static var notNow: String { String(localized: "Not Now") }

    static var playlistDetail: String {
        String(localized: "Say what you want to hear and Flaccy builds it from the music you own.")
    }

    static var highlights: [ShowcaseFeature] {
        [
            ShowcaseFeature(
                id: "equalizer",
                symbol: "slider.vertical.3",
                title: String(localized: "A Real Equalizer"),
                detail: String(localized: "Shape the sound by hand or in a sentence, with its own setting for every output.")
            ),
            ShowcaseFeature(
                id: "lyrics",
                symbol: "quote.bubble.fill",
                title: String(localized: "Lyrics Worth Sharing"),
                detail: String(localized: "Word by word, with what the song means and lines you can share as a video.")
            ),
            ShowcaseFeature(
                id: "anywhere",
                symbol: "server.rack",
                title: String(localized: "Your Music, Anywhere"),
                detail: String(localized: "Stream from your computer or your own server, at home or away.")
            ),
            ShowcaseFeature(
                id: "playlists",
                symbol: "sparkles",
                title: String(localized: "Playlists From a Sentence"),
                detail: playlistDetail
            ),
        ]
    }

    /// Everything the second page lists. `bringsMusicOverWiFi` is false on the Mac, which has no Wi-Fi Transfer and
    /// reads its music from folders the person points it at.
    static func sections(bringsMusicOverWiFi: Bool) -> [ShowcaseSection] {
        [sound, library(bringsMusicOverWiFi: bringsMusicOverWiFi), lyrics, everywhere]
    }

    private static var sound: ShowcaseSection {
        ShowcaseSection(id: "sound", title: String(localized: "Sound"), features: [
            ShowcaseFeature(
                id: "lossless",
                symbol: "waveform",
                title: String(localized: "Lossless, Untouched"),
                detail: String(localized: "FLAC, ALAC, WAV, AIFF, MP3 and AAC, gapless, with the codec, bit depth and sample rate on every track.")
            ),
            ShowcaseFeature(
                id: "equalizer",
                symbol: "slider.vertical.3",
                title: String(localized: "Equalizer"),
                detail: String(localized: "Drag the curve, tune up to ten bands or describe the sound you want. Every output keeps its own setting.")
            ),
            ShowcaseFeature(
                id: "songVolume",
                symbol: "speaker.wave.2.fill",
                title: String(localized: "Song Volume"),
                detail: String(localized: "Make a quiet song louder or a loud one quieter, and it stays that way.")
            ),
        ])
    }

    private static func library(bringsMusicOverWiFi: Bool) -> ShowcaseSection {
        let bringIn = ShowcaseFeature(
            id: "bringIn",
            symbol: "square.and.arrow.down.fill",
            title: String(localized: "Bring It All In"),
            detail: String(localized: "From Files, a USB drive or a NAS, or over Wi-Fi from your computer's web browser.")
        )
        let rest = [
            ShowcaseFeature(
                id: "organized",
                symbol: "square.stack.fill",
                title: String(localized: "Organized for You"),
                detail: String(localized: "Albums, artists and playlists with fast search, large artwork and duplicate songs listed once.")
            ),
            ShowcaseFeature(
                id: "themes",
                symbol: "paintpalette.fill",
                title: String(localized: "Themes"),
                detail: String(localized: "Six themes that change the colors, type and cover shapes, and four ways to see your albums: grid, wall, list or carousel.")
            ),
            ShowcaseFeature(
                id: "makePlaylist",
                symbol: "sparkles",
                title: String(localized: "Make a Playlist"),
                detail: playlistDetail
            ),
            ShowcaseFeature(
                id: "homeRecap",
                symbol: "clock.arrow.circlepath",
                title: String(localized: "Home and Recap"),
                detail: String(localized: "Mixes from your own listening, what you played on this day and your year in music.")
            ),
        ]
        return ShowcaseSection(
            id: "library", title: String(localized: "Library"), features: bringsMusicOverWiFi ? [bringIn] + rest : rest
        )
    }

    private static var lyrics: ShowcaseSection {
        ShowcaseSection(id: "lyrics", title: String(localized: "Lyrics"), features: [
            ShowcaseFeature(
                id: "synced",
                symbol: "text.alignleft",
                title: String(localized: "Synced Lyrics"),
                detail: String(localized: "Word by word when a song has the timing. Tap a line to jump to it.")
            ),
            ShowcaseFeature(
                id: "meaning",
                symbol: "book.fill",
                title: String(localized: "What This Song Means"),
                detail: String(localized: "The story behind a song and any line of it, one tap away.")
            ),
            ShowcaseFeature(
                id: "shareLyrics",
                symbol: "quote.bubble.fill",
                title: String(localized: "Share Lyrics"),
                detail: String(localized: "Pick the lines you love and get a short video of them over the song itself.")
            ),
        ])
    }

    private static var everywhere: ShowcaseSection {
        ShowcaseSection(id: "everywhere", title: String(localized: "Everywhere"), features: [
            ShowcaseFeature(
                id: "flaccyServer",
                symbol: "desktopcomputer",
                title: String(localized: "Flaccy Server"),
                detail: String(localized: "Play the library on your Mac or PC at home or away, with playlists, loves and history in step.")
            ),
            ShowcaseFeature(
                id: "musicServers",
                symbol: "server.rack",
                title: String(localized: "Music Servers"),
                detail: String(localized: "Navidrome, Jellyfin and other Subsonic servers, with downloads for when you are offline.")
            ),
            ShowcaseFeature(
                id: "devices",
                symbol: "applewatch",
                title: String(localized: "On Every Apple Device"),
                detail: String(localized: "iPhone, iPad, Mac and an Apple Watch that plays without the phone. One purchase covers them all.")
            ),
            ShowcaseFeature(
                id: "lastfm",
                symbol: "dot.radiowaves.left.and.right",
                title: "Last.fm",
                detail: String(localized: "Every play scrobbled, even offline, with listening charts and a wantlist.")
            ),
        ])
    }
}
