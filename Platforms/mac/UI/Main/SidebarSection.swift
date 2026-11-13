import Foundation

enum SidebarSection: Int, CaseIterable {
    case home
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
        case .home: HomeCopy.home
        case .albums: String(localized: "Albums")
        case .songs: String(localized: "Songs")
        case .artists: String(localized: "Artists")
        case .playlists: String(localized: "Playlists")
        case .wantlist: String(localized: "Wantlist")
        case .charts: String(localized: "Charts")
        case .yearInMusic: String(localized: "Year in Music")
        case .listeningGuide: String(localized: "Listening Guide")
        }
    }

    var symbolName: String {
        switch self {
        case .home: "house"
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
        case .home: HomeCopy.home
        case .albums, .songs, .artists, .playlists: String(localized: "Library")
        case .wantlist, .charts, .yearInMusic, .listeningGuide: String(localized: "Discover")
        }
    }
}

extension SidebarSection {

    /// The section's name in saved preferences, which never changes even when
    /// the case order does.
    var identifier: String {
        switch self {
        case .home: "home"
        case .albums: "albums"
        case .songs: "songs"
        case .artists: "artists"
        case .playlists: "playlists"
        case .wantlist: "wantlist"
        case .charts: "charts"
        case .yearInMusic: "yearInMusic"
        case .listeningGuide: "listeningGuide"
        }
    }

    init?(identifier: String) {
        guard let match = Self.allCases.first(where: { $0.identifier == identifier }) else { return nil }
        self = match
    }
}

/// Which section the window opens on: Home, or the one the person was last
/// looking at. Home is the default.
enum LaunchSectionSetting {

    enum Choice: String, CaseIterable {
        case home
        case whereYouLeftOff
    }

    static let choiceKey = "flaccy.mac.launchSection"
    static let lastSectionKey = "flaccy.mac.lastSection"

    static func choice(in defaults: UserDefaults = .standard) -> Choice {
        defaults.string(forKey: choiceKey).flatMap(Choice.init(rawValue:)) ?? .home
    }

    static func setChoice(_ choice: Choice, in defaults: UserDefaults = .standard) {
        defaults.set(choice.rawValue, forKey: choiceKey)
    }

    static func remember(_ section: SidebarSection, in defaults: UserDefaults = .standard) {
        defaults.set(section.identifier, forKey: lastSectionKey)
    }

    /// The section to open on, falling back to Home when nothing was saved.
    static func section(in defaults: UserDefaults = .standard) -> SidebarSection {
        guard choice(in: defaults) == .whereYouLeftOff else { return .home }
        return defaults.string(forKey: lastSectionKey).flatMap(SidebarSection.init(identifier:)) ?? .home
    }
}

/// The section the content column is showing, for chrome that belongs to one
/// section only.
enum ActiveSection {
    static var current: SidebarSection?
}

extension Notification.Name {
    static let flaccySectionDidChange = Notification.Name("flaccy.mac.sectionDidChange")
    static let flaccyCustomizeHome = Notification.Name("flaccy.mac.customizeHome")
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
