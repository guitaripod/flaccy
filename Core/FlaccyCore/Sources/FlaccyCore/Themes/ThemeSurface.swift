import Foundation

/// The parts of an Apple client a palette colors: the backgrounds, text at its
/// four strengths, hairlines and fills the system would otherwise supply. One
/// mapping, so iPhone, iPad and Mac dress a theme the same way.
public enum ThemeSurface: String, Sendable, CaseIterable {
    case background
    case groupedBackground
    case card
    case raisedCard
    case bar
    case sidebar
    case label
    case secondaryLabel
    case tertiaryLabel
    case quaternaryLabel
    case separator
    case fill
    case strongFill
    case faintFill
}

/// A color with how opaque it is drawn.
public struct ThemeInk: Equatable, Sendable {
    public let color: ThemeColor
    public let alpha: Double

    public init(_ color: ThemeColor, alpha: Double = 1.0) {
        self.color = color
        self.alpha = alpha
    }
}

extension ThemePalette {

    static let lightText = ThemeColor(0xff, 0xff, 0xff)
    static let darkText = ThemeColor(0x1c, 0x1c, 0x1e)

    /// The text color this palette is read in: its own when the scheme states
    /// one, otherwise white on a dark window and near-black on a light one.
    public var readableText: ThemeColor {
        text ?? (window.luminance < 0.4 ? ThemePalette.lightText : ThemePalette.darkText)
    }

    /// What a surface is painted with under this palette.
    public func ink(for surface: ThemeSurface) -> ThemeInk {
        let text = readableText
        switch surface {
        case .background: return ThemeInk(view)
        case .groupedBackground: return ThemeInk(window)
        case .card: return ThemeInk(card)
        case .raisedCard: return ThemeInk(popover)
        case .bar: return ThemeInk(headerbar)
        case .sidebar: return ThemeInk(sidebar)
        case .label: return ThemeInk(text)
        case .secondaryLabel: return ThemeInk(text, alpha: 0.62)
        case .tertiaryLabel: return ThemeInk(text, alpha: 0.34)
        case .quaternaryLabel: return ThemeInk(text, alpha: 0.2)
        case .separator: return ThemeInk(text, alpha: 0.16)
        case .fill: return ThemeInk(text, alpha: 0.12)
        case .strongFill: return ThemeInk(text, alpha: 0.18)
        case .faintFill: return ThemeInk(text, alpha: 0.07)
        }
    }
}

/// How a theme's font list reads on an Apple client: the first family the
/// device has, or one of the system's own designs for a generic name.
public enum ThemeFontFace: Equatable, Sendable {
    case monospaced
    case serif
    case rounded
    case family(String)

    /// The face for a comma-separated font list, given a way to ask whether
    /// a family is installed. `nil` means the system's own font: nothing in
    /// the list is installed, or the list names the system font first.
    public static func resolve(_ families: String?, isInstalled: (String) -> Bool) -> ThemeFontFace? {
        guard let families else { return nil }
        for raw in families.split(separator: ",") {
            let family = raw.trimmingCharacters(in: .whitespaces)
            switch family.lowercased() {
            case "": continue
            case "monospace", "ui-monospace": return .monospaced
            case "serif", "ui-serif": return .serif
            case "ui-rounded": return .rounded
            case "sans-serif", "system-ui", "ui-sans-serif": return nil
            default:
                if isInstalled(family) { return .family(family) }
            }
        }
        return nil
    }
}
