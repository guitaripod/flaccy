import AppKit
import FlaccyCore

/// Every system color the Mac app paints with that a theme can replace, each
/// with the surface it stands for. Under Flaccy's own theme each one resolves
/// to exactly the system color it is named after.
nonisolated enum MacThemedColor: CaseIterable, Sendable {
    case label
    case secondaryLabel
    case tertiaryLabel
    case quaternaryLabel
    case windowBackground
    case controlBackground
    case textBackground
    case underPageBackground
    case separator
    case accent
    case sidebar
    case bar
    case card

    var systemColor: NSColor {
        switch self {
        case .label: .labelColor
        case .secondaryLabel: .secondaryLabelColor
        case .tertiaryLabel: .tertiaryLabelColor
        case .quaternaryLabel: .quaternaryLabelColor
        case .windowBackground: .windowBackgroundColor
        case .controlBackground: .controlBackgroundColor
        case .textBackground: .textBackgroundColor
        case .underPageBackground: .underPageBackgroundColor
        case .separator: .separatorColor
        case .accent: .controlAccentColor
        case .sidebar, .bar: .clear
        case .card: .controlBackgroundColor
        }
    }

    /// What the palette paints this color with.
    func ink(in palette: ThemePalette) -> ThemeInk {
        switch self {
        case .label: palette.ink(for: .label)
        case .secondaryLabel: palette.ink(for: .secondaryLabel)
        case .tertiaryLabel: palette.ink(for: .tertiaryLabel)
        case .quaternaryLabel: palette.ink(for: .quaternaryLabel)
        case .windowBackground: palette.ink(for: .groupedBackground)
        case .controlBackground, .textBackground: palette.ink(for: .background)
        case .underPageBackground: palette.ink(for: .sidebar)
        case .separator: palette.ink(for: .separator)
        case .accent: ThemeInk(palette.accent)
        case .sidebar: palette.ink(for: .sidebar)
        case .bar: palette.ink(for: .bar)
        case .card: palette.ink(for: .card)
        }
    }

    /// The color to paint with: the system's own until a theme first paints,
    /// so the look every release shipped with has nothing standing in for it,
    /// and from then on the themed color, made once because a label's color
    /// is matched against it by identity.
    var color: NSColor {
        ThemePalettes.hasPainted ? themed : systemColor
    }

    private var themed: NSColor {
        MacThemedColor.colors[self] ?? systemColor
    }

    private static let colors: [MacThemedColor: NSColor] = Dictionary(
        uniqueKeysWithValues: allCases.map { ($0, $0.dynamic()) }
    )

    private func dynamic() -> NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            guard let palette = ThemePalettes.palette(dark: dark) else { return systemColor }
            return NSColor(ink(in: palette))
        }
    }

    /// The same themed color as a new object, for a window, which only
    /// repaints its background when it is handed a color it does not have.
    func fresh() -> NSColor {
        dynamic()
    }

    private static let text: [MacThemedColor] = [.label, .secondaryLabel, .tertiaryLabel, .quaternaryLabel]

    /// The themed color that stands in for `system`, when it is one of the
    /// text colors a theme replaces.
    static func replacingText(_ system: NSColor) -> NSColor? {
        if let match = text.first(where: { $0.systemColor == system }) { return match.themed }
        return system == NSColor.controlTextColor || system == NSColor.textColor ? MacThemedColor.label.themed : nil
    }

    /// The system color a themed text color stood in for, so a label goes
    /// back to exactly what it had once no theme paints.
    static func systemText(replacedBy themed: NSColor) -> NSColor? {
        text.first { $0.themed === themed }?.systemColor
    }
}

extension NSColor {

    nonisolated convenience init(_ ink: ThemeInk) {
        self.init(
            srgbRed: CGFloat(ink.color.red) / 255,
            green: CGFloat(ink.color.green) / 255,
            blue: CGFloat(ink.color.blue) / 255,
            alpha: CGFloat(ink.alpha)
        )
    }

    nonisolated static var flaccyLabel: NSColor { MacThemedColor.label.color }
    nonisolated static var flaccySecondaryLabel: NSColor { MacThemedColor.secondaryLabel.color }
    nonisolated static var flaccyTertiaryLabel: NSColor { MacThemedColor.tertiaryLabel.color }
    nonisolated static var flaccyQuaternaryLabel: NSColor { MacThemedColor.quaternaryLabel.color }
    nonisolated static var flaccyWindowBackground: NSColor { MacThemedColor.windowBackground.color }
    nonisolated static var flaccyControlBackground: NSColor { MacThemedColor.controlBackground.color }
    nonisolated static var flaccyTextBackground: NSColor { MacThemedColor.textBackground.color }
    nonisolated static var flaccyUnderPageBackground: NSColor { MacThemedColor.underPageBackground.color }
    nonisolated static var flaccySeparator: NSColor { MacThemedColor.separator.color }
    nonisolated static var flaccyAccent: NSColor { MacThemedColor.accent.color }
    nonisolated static var flaccyCard: NSColor { MacThemedColor.card.color }

    /// The color that reads on the worn theme's accent: the theme's own, or
    /// white on the system's accent.
    nonisolated static var flaccyOnAccent: NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            guard let palette = ThemePalettes.palette(dark: dark) else { return .white }
            return NSColor(ThemeInk(palette.onAccent))
        }
    }
}
