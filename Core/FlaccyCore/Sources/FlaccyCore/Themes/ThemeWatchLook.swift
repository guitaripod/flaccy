import Foundation

/// What the watch wears of the phone's theme: the accent, the text color, the
/// typeface and the cover shape, as the theme draws them in the dark the
/// watch is always in. The phone sends it in its application context; the
/// watch has no themes folder of its own, so it is told the outcome and not
/// the theme.
public struct ThemeWatchLook: Codable, Equatable, Sendable {

    /// The theme's id. Flaccy's own means the watch's own look, with the
    /// accent the phone sends beside this.
    public var pack: String
    /// 0xRRGGBB.
    public var accent: UInt32
    /// The theme's text color, when it states one.
    public var text: UInt32?
    /// The theme's font lists, as written in its document.
    public var fonts: String?
    public var headings: String?
    public var covers: String

    public init(look: ThemeLook) {
        let palette = look.palette(dark: true)
        pack = look.pack.id
        accent = palette.accent.packed
        text = palette.text?.packed
        fonts = look.interfaceFont
        headings = look.headingFont
        covers = look.covers.id
    }

    /// Whether this is Flaccy's own theme, which leaves the watch as it was.
    public var isOwnLook: Bool { pack == ThemeLibrary.defaultID }

    public var coverShape: ThemePack.CoverShape {
        ThemePack.CoverShape(rawValue: covers) ?? .rounded
    }

    /// The face for body text. The watch has only the system's designs, so a
    /// named family falls through to the generic name that ends its list.
    public var bodyFace: ThemeFontFace? {
        ThemeFontFace.resolve(fonts) { _ in false }
    }

    public var headingFace: ThemeFontFace? {
        ThemeFontFace.resolve(headings) { _ in false }
    }

    /// The corner radius of a cover `side` points wide whose own radius is
    /// `radius`.
    public func coverRadius(_ radius: Double, side: Double) -> Double {
        switch coverShape {
        case .rounded: radius
        case .square: 0
        case .circle: side / 2
        }
    }

    public var encoded: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)) ?? Data()
    }

    public init?(encoded data: Data?) {
        guard let data, let look = try? JSONDecoder().decode(ThemeWatchLook.self, from: data) else { return nil }
        self = look
    }
}
