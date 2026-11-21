import FlaccyCore
import Foundation

/// The words of the theme pages, one place for iPhone, iPad and Mac.
nonisolated enum ThemeCopy {

    static var theme: String { String(localized: "Theme") }
    static var colors: String { String(localized: "Colors") }
    static var variant: String { String(localized: "Variant") }
    static var albumsView: String { String(localized: "Albums View") }
    static var themesChoice: String { String(localized: "Theme’s Choice") }
    static var covers: String { String(localized: "Covers") }
    static var corners: String { String(localized: "Corners") }
    static var sharp: String { String(localized: "Sharp") }
    static var standard: String { String(localized: "Standard") }
    static var round: String { String(localized: "Round") }
    static var soft: String { String(localized: "Soft") }
    static var font: String { String(localized: "Font") }
    static var fontSystem: String { String(localized: "System") }
    static var fontRounded: String { String(localized: "Rounded") }
    static var fontSerif: String { String(localized: "Serif") }
    static var fontMonospaced: String { String(localized: "Monospaced") }
    static var fontChoose: String { String(localized: "Choose a Font…") }
    static var reset: String { String(localized: "Reset to the Theme") }
    static var ownChoices: String { String(localized: "Your Own Choices") }
    static var ownChoicesFooter: String { String(localized: "These hold whichever theme is on.") }
    static var ownThemes: String { String(localized: "Your Own Themes") }
    static var openFolder: String { String(localized: "Open Themes Folder") }
    static var folderDidNotOpen: String {
        String(localized: "The themes folder did not open. In the Files app, open Flaccy’s folder and look for Themes.")
    }
    static var windowGlow: String { String(localized: "Window Glow") }
    static func copied(folder: String) -> String {
        String(localized: "Copied. Change theme.toml in Themes › \(folder) and the app follows.")
    }
    static var copyFailed: String {
        String(localized: "The theme could not be copied. Check that the Themes folder can be written to and try again.")
    }
    static func copyToChange(_ name: String) -> String { String(localized: "Copy \(name) to Change It") }
    static var ownThemesFooter: String {
        String(localized: "A theme is a folder holding a theme.toml. Put it in the Themes folder and it appears here.")
    }

    static func name(of view: ThemePack.AlbumsView) -> String {
        switch view {
        case .grid: String(localized: "Grid")
        case .wall: String(localized: "Wall")
        case .list: String(localized: "List")
        case .carousel: String(localized: "Carousel")
        }
    }

    static func name(of shape: ThemePack.CoverShape) -> String {
        switch shape {
        case .rounded: String(localized: "Rounded")
        case .square: String(localized: "Square")
        case .circle: String(localized: "Circle")
        }
    }

    /// What a corner scale is called.
    static func cornersName(_ scale: Double) -> String {
        if scale <= ThemePack.cornersSharp { return sharp }
        if scale < ThemePack.cornersStandard { return soft }
        if scale == ThemePack.cornersStandard { return standard }
        return round
    }

    /// A variant's name in the person's language when it is one of the words
    /// the app already has (Grid, List, Wall, Carousel, Large Wall); a name
    /// only a theme's author knows stays as they wrote it.
    static func variantName(_ name: String) -> String {
        switch name {
        case "Grid": String(localized: "Grid")
        case "List": String(localized: "List")
        case "Wall": String(localized: "Wall")
        case "Carousel": String(localized: "Carousel")
        case "Large Wall": String(localized: "Large Wall")
        default: name
        }
    }

    /// Why the light and dark switch does nothing under this look, or nothing
    /// to say when the look follows it.
    static func modeNote(for look: ThemeLook) -> String? {
        let owner = look.wornScheme.appearance != nil ? look.wornScheme.name : look.pack.name
        switch look.appearance {
        case .dark: return String(localized: "\(owner) is always dark.")
        case .light: return String(localized: "\(owner) is always light.")
        case .any: return nil
        }
    }
}
