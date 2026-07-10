import Foundation

enum SidebarSection: Int, CaseIterable {
    case albums
    case songs
    case artists
    case playlists
    case wantlist
    case charts
    case yearInMusic
    case listeningGuide

    var title: String {
        switch self {
        case .albums: "Albums"
        case .songs: "Songs"
        case .artists: "Artists"
        case .playlists: "Playlists"
        case .wantlist: "Wantlist"
        case .charts: "Charts"
        case .yearInMusic: "Year in Music"
        case .listeningGuide: "Listening Guide"
        }
    }

    var symbolName: String {
        switch self {
        case .albums: "square.grid.2x2"
        case .songs: "music.note.list"
        case .artists: "music.microphone"
        case .playlists: "list.star"
        case .wantlist: "sparkles.rectangle.stack"
        case .charts: "chart.bar.xaxis"
        case .yearInMusic: "calendar.badge.clock"
        case .listeningGuide: "book"
        }
    }

    var groupTitle: String {
        switch self {
        case .albums, .songs, .artists, .playlists: "Library"
        case .wantlist, .charts, .yearInMusic, .listeningGuide: "Discover"
        }
    }
}

extension Notification.Name {
    static let flaccyShowSection = Notification.Name("flaccy.mac.showSection")
    static let flaccyToggleQueue = Notification.Name("flaccy.mac.toggleQueue")
    static let flaccyToggleLyrics = Notification.Name("flaccy.mac.toggleLyrics")
    static let flaccyToggleNowPlaying = Notification.Name("flaccy.mac.toggleNowPlaying")
    static let flaccyFocusSearch = Notification.Name("flaccy.mac.focusSearch")
    static let flaccyShowSettings = Notification.Name("flaccy.mac.showSettings")
}

enum SectionNotificationKey {
    static let section = "section"
}
