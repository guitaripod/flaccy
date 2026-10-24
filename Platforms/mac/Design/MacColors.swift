import AppKit

/// Semantic colors for the mac app's chrome surfaces, adaptive across the aqua
/// and dark-aqua appearances. Screens rendered over dark album-art backdrops
/// force `.darkAqua` and intentionally keep pure-white foregrounds via
/// `onArtwork`; every other (system-appearance) surface routes through the
/// adaptive members here so it reads correctly in both light and dark mode.
enum MacColors {

    static let primaryLabel = NSColor.labelColor
    static let secondaryLabel = NSColor.secondaryLabelColor
    static let tertiaryLabel = NSColor.tertiaryLabelColor
    static let quaternaryLabel = NSColor.quaternaryLabelColor
    static let separator = NSColor.separatorColor

    /// A neutral film that reads correctly in both appearances: a light veil in
    /// dark mode, a dark veil in light mode. Pass a distinct `light` alpha when
    /// the dark-mode weight would be too heavy against a bright background.
    static func fill(_ darkAlpha: CGFloat, light lightAlpha: CGFloat? = nil) -> NSColor {
        let resolvedLight = lightAlpha ?? darkAlpha
        return NSColor(name: nil) { appearance in
            appearance.isDark
                ? NSColor.white.withAlphaComponent(darkAlpha)
                : NSColor.black.withAlphaComponent(resolvedLight)
        }
    }

    /// Pure-white foreground for content laid over dark album-art backdrops,
    /// where the surface is dark regardless of the system appearance.
    static func onArtwork(_ alpha: CGFloat = 1) -> NSColor {
        NSColor.white.withAlphaComponent(alpha)
    }
}

extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}
