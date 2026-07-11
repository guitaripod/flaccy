import AppKit

/// Artwork-palette gradient backdrop: a diagonal color field under a
/// readability scrim, crossfaded when the palette changes. `vivid` mode (the
/// whole-window now-playing wash) boosts the palette's saturation and lift so
/// even dark covers throw a captivating colored glow, under a lighter scrim;
/// the default subtle mode sits behind scroll-heavy detail surfaces. Port of
/// the iOS AmbientPaletteBackdropView.
final class AmbientBackdropView: NSView {

    private let gradientLayer = CAGradientLayer()
    private let glowLayer = CAGradientLayer()
    private let scrimLayer = CAGradientLayer()
    private let vivid: Bool

    private static let crossfadeDuration: CFTimeInterval = 0.8

    init(vivid: Bool = false) {
        self.vivid = vivid
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        gradientLayer.startPoint = CGPoint(x: 0.06, y: 1)
        gradientLayer.endPoint = CGPoint(x: 0.94, y: 0)
        layer?.addSublayer(gradientLayer)

        // Vivid mode adds a soft radial glow of the dominant color rising from
        // the bottom (where the now-playing bar lives), like a stage wash.
        if vivid {
            glowLayer.type = .radial
            glowLayer.startPoint = CGPoint(x: 0.5, y: -0.15)
            glowLayer.endPoint = CGPoint(x: 1.35, y: 1.0)
            layer?.addSublayer(glowLayer)
        }

        let scrim: [CGFloat] = vivid ? [0.40, 0.34, 0.46] : [0.82, 0.55, 0.30]
        scrimLayer.colors = scrim.map { NSColor.black.withAlphaComponent($0).cgColor }
        scrimLayer.locations = vivid ? [0, 0.7, 1] : [0, 0.5, 1]
        layer?.addSublayer(scrimLayer)

        apply(ArtworkPaletteExtractor.fallbackPalette(seed: "flaccy"), animated: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(_ palette: ArtworkPalette, animated: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? Self.crossfadeDuration : 0)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        gradientLayer.colors = fieldColors(from: palette)
        if vivid {
            let d = boosted(dominant(of: palette))
            glowLayer.colors = [
                d.withAlphaComponent(0.55).cgColor,
                d.withAlphaComponent(0.22).cgColor,
                d.withAlphaComponent(0.0).cgColor,
            ]
            glowLayer.locations = [0, 0.45, 1]
        }
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradientLayer.frame = bounds
        glowLayer.frame = bounds
        scrimLayer.frame = bounds
        CATransaction.commit()
    }

    private func dominant(of palette: ArtworkPalette) -> NSColor {
        palette.colors.first ?? NSColor(white: 0.15, alpha: 1)
    }

    /// Lifts a (often dark) cover color into a saturated, mid-bright glow color.
    private func boosted(_ color: NSColor) -> NSColor {
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        // Floor keeps dark covers visible; the hard ceiling bounds composited
        // luminance so a bright/white cover can never flash-bang the window.
        return NSColor(hue: h, saturation: min(max(s, 0.55), 0.88), brightness: min(max(b, 0.30), 0.42), alpha: 1)
    }

    private func fieldColors(from palette: ArtworkPalette) -> [CGColor] {
        var colors = palette.colors
        while colors.count < 4 {
            colors.append(colors.last ?? NSColor(white: 0.15, alpha: 1))
        }
        return colors.prefix(4).map { color in
            if vivid {
                let b = boosted(color)
                var r: CGFloat = 0, g: CGFloat = 0, bl: CGFloat = 0, a: CGFloat = 0
                b.getRed(&r, green: &g, blue: &bl, alpha: &a)
                return NSColor(red: r * 0.55, green: g * 0.55, blue: bl * 0.55, alpha: 1).cgColor
            }
            var r: CGFloat = 0, g: CGFloat = 0, bl: CGFloat = 0, a: CGFloat = 0
            let rgb = color.usingColorSpace(.deviceRGB) ?? color
            rgb.getRed(&r, green: &g, blue: &bl, alpha: &a)
            return NSColor(red: r * 0.6, green: g * 0.6, blue: bl * 0.6, alpha: 1).cgColor
        }
    }
}
