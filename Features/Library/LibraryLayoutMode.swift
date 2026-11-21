import FlaccyCore
import Foundation

/// How the Albums and Songs lists are laid out, cycled from a single nav-bar
/// button. Grid is a cover wall with titles, list is artwork with
/// title/subtitle rows, compact is dense single-line rows; Albums can also be a
/// wall of bare covers or a carousel, which is where a theme's layout shows.
/// Songs keeps its own remembered mode; Albums takes its from the worn theme
/// until the person switches it.
nonisolated enum LibraryLayoutMode: String, CaseIterable, Sendable {
    case grid
    case wall
    case list
    case compact
    case carousel

    private static let storageKey = "libraryLayoutMode"

    /// The modes Songs offers, and the three every release before themes had.
    static let songModes: [LibraryLayoutMode] = [.grid, .list, .compact]

    static var persisted: LibraryLayoutMode {
        let stored = LibraryLayoutMode(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .grid
        return songModes.contains(stored) ? stored : .grid
    }

    /// Remembers the mode for Songs. A wall or a carousel is Albums' alone and
    /// is remembered with the theme instead.
    func persist() {
        guard LibraryLayoutMode.songModes.contains(self) else { return }
        UserDefaults.standard.set(rawValue, forKey: Self.storageKey)
    }

    /// The mode Albums shows for a theme's view, with `compactRows` choosing
    /// between the two kinds of list.
    init(albums view: ThemePack.AlbumsView, compactRows: Bool) {
        switch view {
        case .grid: self = .grid
        case .wall: self = .wall
        case .list: self = compactRows ? .compact : .list
        case .carousel: self = .carousel
        }
    }

    /// The theme view this mode is, for remembering it with the theme.
    var albumsView: ThemePack.AlbumsView {
        switch self {
        case .grid: .grid
        case .wall: .wall
        case .list, .compact: .list
        case .carousel: .carousel
        }
    }

    /// The next mode when the toggle is tapped: every mode in turn on Albums,
    /// grid → list → compact on Songs.
    func next(onAlbums: Bool) -> LibraryLayoutMode {
        let cycle = onAlbums ? LibraryLayoutMode.allCases : LibraryLayoutMode.songModes
        let at = cycle.firstIndex(of: self) ?? 0
        return cycle[(at + 1) % cycle.count]
    }

    /// The SF Symbol shown on the toggle for the *current* mode.
    var icon: String {
        switch self {
        case .grid: "square.grid.2x2"
        case .wall: "square.grid.3x3.fill"
        case .list: "list.bullet"
        case .compact: "rectangle.compress.vertical"
        case .carousel: "rectangle.split.3x1"
        }
    }

    var displayName: String {
        switch self {
        case .grid: String(localized: "Grid")
        case .wall: String(localized: "Wall")
        case .list: String(localized: "List")
        case .compact: String(localized: "Compact")
        case .carousel: String(localized: "Carousel")
        }
    }

    var accessibilityLabel: String {
        String(localized: "Layout: \(displayName). Double tap to change.")
    }

    /// Non-localized counterpart of `accessibilityLabel`, so UI tests can both
    /// find the toggle and tell which mode it is currently showing.
    var accessibilityIdentifier: String {
        "library.layoutToggle.\(rawValue)"
    }
}
