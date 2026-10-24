import AppKit

/// Artwork-palette gradient backdrop: a diagonal color field under a
/// readability scrim, crossfaded when the palette changes. `vivid` mode (the
/// whole-window library wash) boosts the palette's saturation and lift so even
/// dark covers throw a captivating colored glow; it follows the system
/// appearance, settling into a light pastel wash in light mode and a deep
/// stage-lit field in dark mode so the chrome content stays readable either
/// way. The default subtle mode sits behind the always-dark detail surfaces.
/// Port of the iOS AmbientPaletteBackdropView.
final class AmbientBackdropView: NSView {

    private let gradientLayer = CAGradientLayer()
    private let glowLayer = CAGradientLayer()
    private let scrimLayer = CAGradientLayer()
    private let vivid: Bool
    private var currentPalette: ArtworkPalette

    private static let crossfadeDuration: CFTimeInterval = 0.8

    init(vivid: Bool = false) {
        self.vivid = vivid
        self.currentPalette = ArtworkPaletteExtractor.fallbackPalette(seed: "flaccy")
        super.init(frame: .zero)
        wantsLayer = true

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

        scrimLayer.locations = vivid ? [0, 0.7, 1] : [0, 0.5, 1]
        layer?.addSublayer(scrimLayer)

        refresh(animated: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(_ palette: ArtworkPalette, animated: Bool) {
        currentPalette = palette
        refresh(animated: animated)
    }

    /// Re-resolves every appearance-dependent layer against the effective
    /// appearance; `layer` CGColors don't auto-adapt, so this also runs on every
    /// light/dark switch.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh(animated: false)
    }

    private func refresh(animated: Bool) {
        let dark = effectiveAppearance.isDark
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? Self.crossfadeDuration : 0)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        if !animated { CATransaction.setDisableActions(true) }
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        gradientLayer.colors = fieldColors(from: currentPalette, dark: dark)
        scrimLayer.colors = scrimColors(dark: dark)
        if vivid {
            let d = boosted(dominant(of: currentPalette))
            let peak: CGFloat = dark ? 0.55 : 0.30
            glowLayer.colors = [
                d.withAlphaComponent(peak).cgColor,
                d.withAlphaComponent(peak * 0.4).cgColor,
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

    /// The readability scrim: a black veil that deepens the field in dark mode,
    /// a white veil that lifts it toward the light window background in light
    /// mode. The subtle backdrop only ever renders under a dark appearance.
    private func scrimColors(dark: Bool) -> [CGColor] {
        let base: NSColor = dark ? .black : .white
        let alphas: [CGFloat]
        if vivid {
            alphas = dark ? [0.40, 0.34, 0.46] : [0.34, 0.26, 0.42]
        } else {
            alphas = [0.82, 0.55, 0.30]
        }
        return alphas.map { base.withAlphaComponent($0).cgColor }
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

    private func fieldColors(from palette: ArtworkPalette, dark: Bool) -> [CGColor] {
        var colors = palette.colors
        while colors.count < 4 {
            colors.append(colors.last ?? NSColor(white: 0.15, alpha: 1))
        }
        return colors.prefix(4).map { color in
            if vivid {
                return vividField(from: color, dark: dark)
            }
            var r: CGFloat = 0, g: CGFloat = 0, bl: CGFloat = 0, a: CGFloat = 0
            let rgb = color.usingColorSpace(.deviceRGB) ?? color
            rgb.getRed(&r, green: &g, blue: &bl, alpha: &a)
            if dark {
                return NSColor(red: r * 0.6, green: g * 0.6, blue: bl * 0.6, alpha: 1).cgColor
            }
            let lift: CGFloat = 0.7
            return NSColor(
                red: r * (1 - lift) + lift,
                green: g * (1 - lift) + lift,
                blue: bl * (1 - lift) + lift,
                alpha: 1
            ).cgColor
        }
    }

    /// In dark mode the boosted color is dimmed into a deep field; in light mode
    /// it is blended toward white into a pastel tint so dark chrome text reads.
    private func vividField(from color: NSColor, dark: Bool) -> CGColor {
        let b = boosted(color)
        var r: CGFloat = 0, g: CGFloat = 0, bl: CGFloat = 0, a: CGFloat = 0
        b.getRed(&r, green: &g, blue: &bl, alpha: &a)
        if dark {
            return NSColor(red: r * 0.55, green: g * 0.55, blue: bl * 0.55, alpha: 1).cgColor
        }
        let lift: CGFloat = 0.62
        return NSColor(
            red: r * (1 - lift) + lift,
            green: g * (1 - lift) + lift,
            blue: bl * (1 - lift) + lift,
            alpha: 1
        ).cgColor
    }
}
