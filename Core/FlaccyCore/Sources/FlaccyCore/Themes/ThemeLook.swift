import Foundation

/// Every color a client is drawn with in one mode.
public struct ThemePalette: Equatable, Sendable {
    public var accent: ThemeColor
    public var onAccent: ThemeColor
    public var accentText: ThemeColor
    public var washA: ThemeColor
    public var washB: ThemeColor
    public var card: ThemeColor
    public var window: ThemeColor
    public var headerbar: ThemeColor
    public var sidebar: ThemeColor
    public var view: ThemeColor
    public var popover: ThemeColor
    public var text: ThemeColor?

    /// The least contrast accent-colored text keeps against the window it is on.
    public static let accentTextContrast = 4.5

    /// The accent as a text color: the hue at `lightness`, moved further from
    /// the window's own lightness in small steps until it reads.
    static func accentText(
        on window: ThemeColor, hue: Double, saturation: Double, lightness: Double, dark: Bool
    ) -> ThemeColor {
        let step = dark ? 0.02 : -0.02
        var lightness = lightness
        while true {
            let text = ThemeHSL(hue: hue, saturation: saturation, lightness: lightness).color
            let next = lightness + step
            if text.contrast(with: window) >= accentTextContrast || !(0.04...0.96).contains(next) {
                return text
            }
            lightness = next
        }
    }

    /// Works a whole palette out of one seed color. Album artwork often yields
    /// muddy or blown-out colors, so the hue is kept while saturation and
    /// lightness are pulled into a legible, vivid band.
    public static func derived(seed: ThemeColor, muted: Bool, dark: Bool) -> ThemePalette {
        let base = ThemeHSL(seed)
        let hue = base.hue
        let saturation = muted ? min(max(base.saturation * 0.35, 0.0), 0.18) : min(max(base.saturation, 0.55), 0.92)
        let accent = ThemeHSL(hue: hue, saturation: saturation, lightness: dark ? 0.56 : 0.50).color

        func tint(_ scale: Double, _ cap: Double, _ lightness: Double, _ shift: Double) -> ThemeColor {
            ThemeHSL(
                hue: ThemeHSL.wrapped(hue + shift, by: 360.0),
                saturation: min(saturation * scale, cap),
                lightness: lightness
            ).color
        }

        let washA = dark ? tint(0.9, 0.85, 0.20, 0.0) : tint(0.70, 0.60, 0.93, 0.0)
        let washB = dark ? tint(0.85, 0.80, 0.11, 28.0) : tint(0.60, 0.50, 0.97, 28.0)
        let card = dark ? tint(0.40, 0.35, 0.145, 0.0) : tint(0.30, 0.22, 0.985, 0.0)
        let window = dark ? tint(0.35, 0.28, 0.082, 0.0) : tint(0.28, 0.18, 0.965, 0.0)
        let headerbar = dark ? tint(0.35, 0.26, 0.118, 0.0) : tint(0.26, 0.16, 0.982, 0.0)
        let sidebar = dark ? tint(0.35, 0.26, 0.10, 0.0) : tint(0.30, 0.20, 0.955, 0.0)
        let view = dark ? tint(0.30, 0.22, 0.105, 0.0) : tint(0.20, 0.14, 0.995, 0.0)

        return ThemePalette(
            accent: accent,
            onAccent: accent.legibleForeground,
            accentText: accentText(
                on: window, hue: hue, saturation: min(saturation + 0.05, 0.95), lightness: dark ? 0.72 : 0.42,
                dark: dark
            ),
            washA: washA,
            washB: washB,
            card: card,
            window: window,
            headerbar: headerbar,
            sidebar: sidebar,
            view: view,
            popover: headerbar,
            text: nil
        )
    }

    /// This palette with every color a scheme states exactly put in its place.
    /// An exact accent takes a legible foreground with it unless one is stated
    /// too, and an exact header bar carries the popovers that share its color.
    func with(exact: ThemePack.Colors) -> ThemePalette {
        let accent = exact.accent ?? self.accent
        let headerbar = exact.headerbar ?? self.headerbar
        return ThemePalette(
            accent: accent,
            onAccent: exact.onAccent ?? (exact.accent != nil ? accent.legibleForeground : onAccent),
            accentText: exact.accentText ?? accentText,
            washA: exact.washA ?? washA,
            washB: exact.washB ?? washB,
            card: exact.card ?? card,
            window: exact.window ?? window,
            headerbar: headerbar,
            sidebar: exact.sidebar ?? sidebar,
            view: exact.view ?? view,
            popover: exact.popover ?? headerbar,
            text: exact.text
        )
    }
}

/// What a client actually wears: a theme with one of its schemes and variants
/// chosen and the person's own choices laid on top. Mirrored in Rust as
/// `linux/shared/src/theme/look.rs`.
public struct ThemeLook: Equatable, Sendable {

    /// The brand rose an artwork-following scheme wears until something plays.
    public static let brandSeed = ThemeColor(0xFF, 0x4D, 0x6D)

    /// Which theme is on, and which of its color schemes and variants.
    public struct Choice: Equatable, Sendable {
        public var pack: String
        public var scheme: String
        public var variant: String

        public init(pack: String = "", scheme: String = "", variant: String = "") {
            self.pack = pack
            self.scheme = scheme
            self.variant = variant
        }
    }

    public var pack: ThemePack
    public var scheme: Int
    public var variant: Int?
    public var interfaceFont: String?
    public var headingFont: String?
    public var corners: Double
    public var covers: ThemePack.CoverShape
    public var shadows: Bool
    public var albums: ThemePack.AlbumsView
    public var coverSize: Int
    public var glow: Bool

    public init(pack: ThemePack, choice: Choice, overrides: ThemePack.Style = ThemePack.Style()) {
        let scheme = pack.schemes.firstIndex { $0.id == choice.scheme } ?? 0
        let variant: Int? =
            pack.variants.isEmpty ? nil : (pack.variants.firstIndex { $0.id == choice.variant } ?? 0)
        let themed = variant.map { pack.variants[$0].style.over(pack.style) } ?? pack.style
        let style = overrides.over(themed)
        self.pack = pack
        self.scheme = scheme
        self.variant = variant
        self.interfaceFont = style.interfaceFont
        self.headingFont = style.headingFont
        self.corners = min(max(style.corners ?? ThemePack.cornersStandard, 0.0), ThemePack.cornersMax)
        self.covers = style.covers ?? .rounded
        self.shadows = style.shadows ?? true
        self.albums = style.albums ?? .grid
        self.coverSize = min(
            max(style.coverSize ?? ThemePack.coverSizeDefault, ThemePack.coverSizeMin), ThemePack.coverSizeMax
        )
        self.glow = style.glow ?? true
    }

    public var wornScheme: ThemePack.Scheme { pack.schemes[scheme] }

    public var wornVariant: ThemePack.Variant? { variant.map { pack.variants[$0] } }

    /// The mode this look insists on: its scheme's when the scheme has one,
    /// otherwise the theme's.
    public var appearance: ThemePack.Appearance {
        wornScheme.appearance ?? pack.appearance
    }

    public var followsArtwork: Bool {
        wornScheme.accent == .artwork
    }

    /// The color everything is derived from: the scheme's own, or the playing
    /// cover's when the scheme follows artwork.
    public func seed(artwork: ThemeColor?) -> ThemeColor {
        switch wornScheme.accent {
        case .fixed(let color): color
        case .artwork: artwork ?? ThemeLook.brandSeed
        }
    }

    public func palette(dark: Bool, artwork: ThemeColor? = nil) -> ThemePalette {
        let scheme = wornScheme
        return ThemePalette.derived(seed: seed(artwork: artwork), muted: scheme.muted, dark: dark)
            .with(exact: dark ? scheme.dark : scheme.light)
    }
}
