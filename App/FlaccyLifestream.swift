import MidgarCore

/// What Flaccy tells Lifestream beyond the shared events: the screens a crash trail may name and the features whose weekly use is counted. Every id here is listed in `registry/apps/flaccy.toml` under `[lifestream]`; the server reads any other as `other`.
enum FlaccyLifestream {
    /// A screen that is only a place: it goes on the crash trail.
    enum Screen: String {
        case home
        case library
        case settings
    }

    /// A screen that is also a feature: opening it goes on the crash trail and counts as using the feature that week.
    enum Feature: String {
        case nowPlaying = "now_playing"
        case equalizer
        case playlistMaker = "playlist_maker"
        case wantlist
        case wifiTransfer = "wifi_transfer"
        case lyrics
    }

    /// Notes that a screen came on.
    static func opened(_ screen: Screen) {
        MidgarTrail.mark(screen.rawValue)
    }

    /// Notes that a feature's screen came on.
    static func opened(_ feature: Feature) {
        MidgarTrail.mark(feature.rawValue)
        MidgarSignals.noteFeature(feature.rawValue)
    }

    /// Notes Flaccy's value moment: a song from the person's own library started to play. Only the first one on an install is sent.
    static func playedOwnMusic() {
        MidgarSignals.noteValue()
    }
}
