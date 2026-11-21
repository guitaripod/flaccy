import AppKit
import FlaccyCore

/// A small drawing of the Mac window as a look would dress it: its colors,
/// its cover shape and corners, and how it lays the albums out. Drawn from
/// the look itself, so a theme somebody made yesterday has one without
/// shipping a picture. The drawing is laid out in a 168 by 112 space and
/// scaled to fit.
final class MacThemePreviewView: NSView {

    static let designSize = NSSize(width: 168, height: 112)

    /// The hue steps, from the accent, the stand-in covers are painted in, so
    /// a preview reads as a shelf of different records.
    private static let coverHues: [Double] = [0, 38, 196, 282, 122, 328, 78, 232]

    var look: ThemeLook? {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// Whether the look is drawn dark here: its own mode when it insists on
    /// one, otherwise the mode the app is in.
    private func drawsDark(_ look: ThemeLook) -> Bool {
        switch look.appearance {
        case .dark: true
        case .light: false
        case .any: effectiveAppearance.isDark
        }
    }

    private static func themeColor(_ color: NSColor) -> ThemeColor {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        func byte(_ part: CGFloat) -> UInt8 { UInt8((min(max(part, 0), 1) * 255).rounded()) }
        return ThemeColor(byte(rgb.redComponent), byte(rgb.greenComponent), byte(rgb.blueComponent))
    }

    /// The palette a preview paints with. Flaccy's own theme is the system's
    /// look, so its preview takes the system's colors and accent.
    private func palette(for look: ThemeLook, dark: Bool) -> ThemePalette {
        var palette = look.palette(dark: dark)
        guard look.pack.id == ThemeLibrary.defaultID else { return palette }
        palette.accent = Self.themeColor(.controlAccentColor)
        palette.window = dark ? ThemeColor(0x1e, 0x1e, 0x20) : ThemeColor(0xf4, 0xf4, 0xf6)
        palette.view = palette.window
        palette.sidebar = dark ? ThemeColor(0x2a, 0x2a, 0x2d) : ThemeColor(0xe6, 0xe6, 0xea)
        palette.card = dark ? ThemeColor(0x32, 0x32, 0x36) : ThemeColor(0xff, 0xff, 0xff)
        palette.text = nil
        return palette
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let look, let context = NSGraphicsContext.current?.cgContext else { return }
        let design = MacThemePreviewView.designSize
        context.saveGState()
        context.scaleBy(x: bounds.width / design.width, y: bounds.height / design.height)
        let dark = drawsDark(look)
        Painter(look: look, palette: palette(for: look, dark: dark), dark: dark).paint()
        context.restoreGState()
    }

    private struct Painter {
        let look: ThemeLook
        let palette: ThemePalette
        let dark: Bool

        private static let sidebarWidth: CGFloat = 40
        private static let contentLeft: CGFloat = 48

        private var text: ThemeColor { palette.readableText }
        private var corners: CGFloat { CGFloat(min(look.corners, ThemePack.cornersRound)) }

        private func fill(_ color: ThemeColor, alpha: Double = 1, _ path: NSBezierPath) {
            NSColor(ThemeInk(color, alpha: alpha)).setFill()
            path.fill()
        }

        private func rounded(_ frame: NSRect, _ radius: CGFloat) -> NSBezierPath {
            NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius)
        }

        private func bar(_ color: ThemeColor, alpha: Double, x: CGFloat, y: CGFloat, width: CGFloat) {
            fill(color, alpha: alpha, rounded(NSRect(x: x, y: y, width: width, height: 2.5), 1.25))
        }

        private func coverColor(_ index: Int) -> ThemeColor {
            let accent = ThemeHSL(palette.accent)
            let hues = MacThemePreviewView.coverHues
            return ThemeHSL(
                hue: accent.hue + hues[index % hues.count], saturation: 0.42, lightness: dark ? 0.44 : 0.62
            ).color
        }

        private func cover(_ index: Int, _ frame: NSRect, alpha: Double = 1, bare: Bool = false) {
            let radius: CGFloat =
                if bare {
                    0
                } else {
                    switch look.covers {
                    case .square: 0
                    case .circle: frame.width / 2
                    case .rounded: frame.width * 0.1 * CGFloat(look.corners)
                    }
                }
            fill(coverColor(index), alpha: alpha, rounded(frame, radius))
        }

        private func sidebar() {
            let size = MacThemePreviewView.designSize
            fill(palette.sidebar, NSBezierPath(rect: NSRect(x: 0, y: 0, width: Self.sidebarWidth, height: size.height)))
            for (index, tint) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                tint.withAlphaComponent(0.75).setFill()
                NSBezierPath(ovalIn: NSRect(x: 6 + CGFloat(index) * 6, y: 6, width: 3.6, height: 3.6)).fill()
            }
            for row in 0..<5 {
                let top = 20 + CGFloat(row) * 9
                if row == 1 {
                    fill(palette.accent, alpha: 0.26, rounded(NSRect(x: 4, y: top - 2.5, width: 32, height: 7.5), 2 * corners))
                }
                bar(text, alpha: row == 1 ? 0.85 : 0.42, x: 8, y: top, width: 18 + CGFloat(row % 3) * 4)
            }
        }

        private func chips() {
            let radius = 3 * corners
            fill(palette.accent, alpha: 0.9, rounded(NSRect(x: Self.contentLeft, y: 8, width: 16, height: 7), radius))
            for index in 0..<2 {
                let frame = NSRect(x: Self.contentLeft + 20 + CGFloat(index) * 22, y: 8, width: 18, height: 7)
                fill(text, alpha: 0.12, rounded(frame, radius))
            }
        }

        private func grid() {
            let side: CGFloat = 23
            for index in 0..<8 {
                let frame = NSRect(
                    x: Self.contentLeft + CGFloat(index % 4) * (side + 6), y: 21 + CGFloat(index / 4) * (side + 12),
                    width: side, height: side
                )
                cover(index, frame)
                bar(text, alpha: 0.55, x: frame.minX, y: frame.maxY + 2.5, width: side * 0.8)
                bar(text, alpha: 0.26, x: frame.minX, y: frame.maxY + 6.5, width: side * 0.5)
            }
        }

        private func wall() {
            let size = MacThemePreviewView.designSize
            let side = (size.width - Self.sidebarWidth) / 4
            for index in 0..<12 {
                let frame = NSRect(
                    x: Self.sidebarWidth + CGFloat(index % 4) * side, y: 19 + CGFloat(index / 4) * side,
                    width: side + 0.5, height: side + 0.5
                )
                cover(index, frame, bare: true)
            }
        }

        private func list() {
            let width = MacThemePreviewView.designSize.width
            for row in 0..<6 {
                let top = 21 + CGFloat(row) * 12
                if row == 1 {
                    let frame = NSRect(x: Self.contentLeft - 3, y: top - 2, width: width - Self.contentLeft - 3, height: 11.5)
                    fill(palette.accent, alpha: 0.22, rounded(frame, 2.5 * corners))
                }
                cover(row, NSRect(x: Self.contentLeft, y: top, width: 7.5, height: 7.5))
                bar(text, alpha: row == 1 ? 0.9 : 0.55, x: Self.contentLeft + 12, y: top + 0.5, width: 40 + CGFloat(row % 3) * 10)
                bar(text, alpha: 0.24, x: Self.contentLeft + 12, y: top + 4.5, width: 26)
                bar(text, alpha: 0.2, x: width - 26, y: top + 2.5, width: 18)
            }
        }

        private func carousel() {
            let width = MacThemePreviewView.designSize.width
            let middle = (width + Self.sidebarWidth) / 2
            let big: CGFloat = 46
            cover(2, NSRect(x: middle - big / 2 - 36, y: 30, width: 30, height: 30), alpha: 0.6)
            cover(3, NSRect(x: middle + big / 2 + 6, y: 30, width: 30, height: 30), alpha: 0.6)
            cover(0, NSRect(x: middle - big / 2, y: 22, width: big, height: big))
            bar(text, alpha: 0.75, x: middle - 20, y: 72, width: 40)
            bar(text, alpha: 0.3, x: middle - 13, y: 77, width: 26)
        }

        private func transport() {
            let size = MacThemePreviewView.designSize
            let frame = NSRect(x: 5, y: size.height - 20, width: size.width - 10, height: 15)
            fill(palette.card, rounded(frame, 6 * corners))
            fill(text, alpha: 0.1, rounded(frame, 6 * corners))
            fill(palette.accent, NSBezierPath(ovalIn: NSRect(x: 11, y: frame.midY - 3, width: 6, height: 6)))
            cover(1, NSRect(x: 30, y: frame.minY + 3, width: 9, height: 9))
            bar(text, alpha: 0.6, x: 43, y: frame.midY - 3.5, width: 34)
            bar(text, alpha: 0.28, x: 43, y: frame.midY + 1, width: 22)
            bar(text, alpha: 0.3, x: size.width - 52, y: frame.midY - 1.25, width: 40)
        }

        func paint() {
            let size = MacThemePreviewView.designSize
            rounded(NSRect(origin: .zero, size: size), 9 * corners).addClip()
            fill(look.albums == .list ? palette.view : palette.window, NSBezierPath(rect: NSRect(origin: .zero, size: size)))
            switch look.albums {
            case .grid: grid()
            case .wall: wall()
            case .list: list()
            case .carousel: carousel()
            }
            sidebar()
            chips()
            transport()
        }
    }
}
