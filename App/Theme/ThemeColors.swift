import FlaccyCore
import os
import UIKit

/// The palettes the app's dynamic colors read. UIKit resolves a dynamic color
/// on whatever thread is drawing, so the palettes sit behind a lock where any
/// thread may read them, apart from the main-actor runtime that sets them.
nonisolated enum ThemePaint {

    private struct Palettes: Sendable {
        var dark: ThemePalette?
        var light: ThemePalette?
    }

    private static let palettes = OSAllocatedUnfairLock(initialState: Palettes())

    /// Sets the palettes to paint with; `nil` for both leaves every surface to
    /// the system, which is how Flaccy's own theme looks.
    static func wear(dark: ThemePalette?, light: ThemePalette?) {
        palettes.withLock { $0 = Palettes(dark: dark, light: light) }
    }

    static func palette(dark: Bool) -> ThemePalette? {
        palettes.withLock { dark ? $0.dark : $0.light }
    }

    /// A color that is `system` under Flaccy's own theme and the palette's
    /// ink for `surface` under any other, resolved again whenever the traits
    /// (the mode, or the theme epoch) change.
    static func color(_ surface: ThemeSurface, system: ThemedColor) -> UIColor {
        UIColor { traits in
            guard let palette = palette(dark: traits.userInterfaceStyle == .dark) else {
                return system.systemColor.resolvedColor(with: traits)
            }
            return UIColor(palette.ink(for: surface))
        }
    }

    /// The accent of the worn theme as a tint, or nothing under Flaccy's own
    /// theme, whose tint is the accent picked in Settings.
    static func tint() -> UIColor? {
        guard palette(dark: true) != nil || palette(dark: false) != nil else { return nil }
        return UIColor { traits in
            let dark = traits.userInterfaceStyle == .dark
            guard let palette = palette(dark: dark) ?? palette(dark: !dark) else { return .systemBlue }
            return UIColor(ThemeInk(palette.accent))
        }
    }

    /// What is drawn on top of the accent, made once.
    static let onAccentColor = onAccent()

    /// What is drawn on top of the accent: the palette's own choice, white
    /// under Flaccy's own theme.
    private static func onAccent() -> UIColor {
        UIColor { traits in
            guard let palette = palette(dark: traits.userInterfaceStyle == .dark) else { return .white }
            return UIColor(ThemeInk(palette.onAccent))
        }
    }
}

extension UIColor {

    nonisolated convenience init(_ ink: ThemeInk) {
        self.init(
            red: CGFloat(ink.color.red) / 255,
            green: CGFloat(ink.color.green) / 255,
            blue: CGFloat(ink.color.blue) / 255,
            alpha: CGFloat(ink.alpha)
        )
    }
}

/// Every system color the app paints with that a theme can replace, each with
/// the surface it stands for. Under Flaccy's own theme each one resolves to
/// exactly the system color it is named after.
nonisolated enum ThemedColor: CaseIterable, Sendable {
    case background
    case secondaryBackground
    case tertiaryBackground
    case groupedBackground
    case secondaryGroupedBackground
    case tertiaryGroupedBackground
    case label
    case secondaryLabel
    case tertiaryLabel
    case quaternaryLabel
    case separator
    case fill
    case secondaryFill
    case tertiaryFill
    case quaternaryFill

    var systemColor: UIColor {
        switch self {
        case .background: .systemBackground
        case .secondaryBackground: .secondarySystemBackground
        case .tertiaryBackground: .tertiarySystemBackground
        case .groupedBackground: .systemGroupedBackground
        case .secondaryGroupedBackground: .secondarySystemGroupedBackground
        case .tertiaryGroupedBackground: .tertiarySystemGroupedBackground
        case .label: .label
        case .secondaryLabel: .secondaryLabel
        case .tertiaryLabel: .tertiaryLabel
        case .quaternaryLabel: .quaternaryLabel
        case .separator: .separator
        case .fill: .systemFill
        case .secondaryFill: .secondarySystemFill
        case .tertiaryFill: .tertiarySystemFill
        case .quaternaryFill: .quaternarySystemFill
        }
    }

    var surface: ThemeSurface {
        switch self {
        case .background: .background
        case .groupedBackground: .groupedBackground
        case .secondaryBackground, .secondaryGroupedBackground: .card
        case .tertiaryBackground, .tertiaryGroupedBackground: .raisedCard
        case .label: .label
        case .secondaryLabel: .secondaryLabel
        case .tertiaryLabel: .tertiaryLabel
        case .quaternaryLabel: .quaternaryLabel
        case .separator: .separator
        case .fill: .strongFill
        case .secondaryFill, .tertiaryFill: .fill
        case .quaternaryFill: .faintFill
        }
    }

    /// The themed color, made once: a dynamic color is cheap to hold and is
    /// compared by identity when a label's color is matched against it.
    var color: UIColor {
        ThemedColor.colors[self] ?? systemColor
    }

    private static let colors: [ThemedColor: UIColor] = Dictionary(
        uniqueKeysWithValues: allCases.map { ($0, ThemePaint.color($0.surface, system: $0)) }
    )

    /// The themed color that stands in for `system`, when it is one a theme replaces.
    static func replacing(_ system: UIColor) -> UIColor? {
        allCases.first { $0.systemColor == system }?.color
    }
}

extension UIColor {
    nonisolated static var flaccyBackground: UIColor { ThemedColor.background.color }
    nonisolated static var flaccySecondaryBackground: UIColor { ThemedColor.secondaryBackground.color }
    nonisolated static var flaccyTertiaryBackground: UIColor { ThemedColor.tertiaryBackground.color }
    nonisolated static var flaccyGroupedBackground: UIColor { ThemedColor.groupedBackground.color }
    nonisolated static var flaccySecondaryGroupedBackground: UIColor { ThemedColor.secondaryGroupedBackground.color }
    nonisolated static var flaccyTertiaryGroupedBackground: UIColor { ThemedColor.tertiaryGroupedBackground.color }
    nonisolated static var flaccyLabel: UIColor { ThemedColor.label.color }
    nonisolated static var flaccySecondaryLabel: UIColor { ThemedColor.secondaryLabel.color }
    nonisolated static var flaccyTertiaryLabel: UIColor { ThemedColor.tertiaryLabel.color }
    nonisolated static var flaccyQuaternaryLabel: UIColor { ThemedColor.quaternaryLabel.color }
    nonisolated static var flaccySeparator: UIColor { ThemedColor.separator.color }
    nonisolated static var flaccyFill: UIColor { ThemedColor.fill.color }
    nonisolated static var flaccySecondaryFill: UIColor { ThemedColor.secondaryFill.color }
    nonisolated static var flaccyTertiaryFill: UIColor { ThemedColor.tertiaryFill.color }
    nonisolated static var flaccyQuaternaryFill: UIColor { ThemedColor.quaternaryFill.color }
    nonisolated static var flaccyOnAccent: UIColor { ThemePaint.onAccentColor }
}

/// A trait that changes whenever the look does, so UIKit resolves every
/// dynamic color again and views that keep `CGColor`s hear about it the same
/// way they hear about light and dark.
nonisolated struct ThemeEpochTrait: UITraitDefinition {
    static let defaultValue = 0
    static let affectsColorAppearance = true
    static let name = "FlaccyThemeEpoch"
}

extension UIMutableTraits {
    var themeEpoch: Int {
        get { self[ThemeEpochTrait.self] }
        set { self[ThemeEpochTrait.self] = newValue }
    }
}
