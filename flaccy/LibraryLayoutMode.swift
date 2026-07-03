import UIKit

/// The visual density of the Albums and Songs lists, cycled from a single
/// nav-bar button and persisted across launches. Grid is a cover wall, list is
/// artwork with title/subtitle rows, compact is dense single-line rows.
nonisolated enum LibraryLayoutMode: String, CaseIterable, Sendable {
    case grid
    case list
    case compact

    private static let storageKey = "libraryLayoutMode"

    static var persisted: LibraryLayoutMode {
        LibraryLayoutMode(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .grid
    }

    func persist() {
        UserDefaults.standard.set(rawValue, forKey: Self.storageKey)
    }

    /// The next mode when the toggle is tapped, wrapping grid → list → compact → grid.
    var next: LibraryLayoutMode {
        switch self {
        case .grid: .list
        case .list: .compact
        case .compact: .grid
        }
    }

    /// The SF Symbol shown on the toggle for the *current* mode.
    var icon: String {
        switch self {
        case .grid: "square.grid.2x2"
        case .list: "list.bullet"
        case .compact: "rectangle.compress.vertical"
        }
    }

    var displayName: String {
        switch self {
        case .grid: "Grid"
        case .list: "List"
        case .compact: "Compact"
        }
    }

    var accessibilityLabel: String {
        "Layout: \(displayName). Double tap to change."
    }
}
