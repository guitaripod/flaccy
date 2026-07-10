import AppKit

/// Static artwork-palette gradient for scroll-heavy detail surfaces: no Metal,
/// no timers — a darkened diagonal color field under a readability scrim,
/// crossfaded when the palette changes. Port of the iOS
/// AmbientPaletteBackdropView.
final class AmbientBackdropView: NSView {

    private let gradientLayer = CAGradientLayer()
    private let scrimLayer = CAGradientLayer()

    private static let crossfadeDuration: CFTimeInterval = 0.8

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        gradientLayer.startPoint = CGPoint(x: 0.1, y: 1)
        gradientLayer.endPoint = CGPoint(x: 0.9, y: 0)
        gradientLayer.colors = Self.cgColors(
            from: ArtworkPaletteExtractor.fallbackPalette(seed: "flaccy")
        )
        layer?.addSublayer(gradientLayer)
        scrimLayer.colors = [
            NSColor.black.withAlphaComponent(0.82).cgColor,
            NSColor.black.withAlphaComponent(0.55).cgColor,
            NSColor.black.withAlphaComponent(0.30).cgColor,
        ]
        scrimLayer.locations = [0, 0.55, 1]
        layer?.addSublayer(scrimLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(_ palette: ArtworkPalette, animated: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? Self.crossfadeDuration : 0)
        gradientLayer.colors = Self.cgColors(from: palette)
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradientLayer.frame = bounds
        scrimLayer.frame = bounds
        CATransaction.commit()
    }

    private static func cgColors(from palette: ArtworkPalette) -> [CGColor] {
        var colors = palette.colors
        while colors.count < 4 {
            colors.append(colors.last ?? NSColor(white: 0.15, alpha: 1))
        }
        return colors.prefix(4).map { color in
            var r: CGFloat = 0
            var g: CGFloat = 0
            var b: CGFloat = 0
            var a: CGFloat = 0
            let rgb = color.usingColorSpace(.deviceRGB) ?? color
            rgb.getRed(&r, green: &g, blue: &b, alpha: &a)
            return NSColor(red: r * 0.6, green: g * 0.6, blue: b * 0.6, alpha: 1).cgColor
        }
    }
}
