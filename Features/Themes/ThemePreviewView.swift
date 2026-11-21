import FlaccyCore
import UIKit

/// A small drawing of the app as a look would dress it: its colors, its cover
/// shape and corners, and how it lays the albums out. Drawn from the look
/// itself, so a theme somebody made yesterday has one without shipping a
/// picture. The drawing is laid out in a 120 by 160 space and scaled to fit.
final class ThemePreviewView: UIView {

    static let designSize = CGSize(width: 120, height: 160)

    /// The hue steps, from the accent, the stand-in covers are painted in, so
    /// a preview reads as a shelf of different records.
    private static let coverHues: [Double] = [0, 38, 196, 282, 122, 328, 78, 232]

    var look: ThemeLook? {
        didSet { setNeedsDisplay() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        contentMode = .redraw
        isAccessibilityElement = false
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeEpochTrait.self]) { (view: ThemePreviewView, _) in
            view.setNeedsDisplay()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Whether the look is drawn dark here: its own mode when it insists on
    /// one, otherwise the mode the app is in.
    private func drawsDark(_ look: ThemeLook) -> Bool {
        switch look.appearance {
        case .dark: true
        case .light: false
        case .any: traitCollection.userInterfaceStyle == .dark
        }
    }

    /// The palette a preview paints with. Flaccy's own theme is the system's
    /// look, so its preview takes the system's colors and the scheme's accent.
    private func palette(for look: ThemeLook, dark: Bool) -> ThemePalette {
        var palette = look.palette(dark: dark)
        guard look.pack.id == ThemeLibrary.defaultID else { return palette }
        let accent = AccentChoice(id: look.wornScheme.id)
        let packed = dark ? accent.dark : accent.light
        palette.accent = ThemeColor(UInt8((packed >> 16) & 0xFF), UInt8((packed >> 8) & 0xFF), UInt8(packed & 0xFF))
        palette.window = dark ? ThemeColor(0, 0, 0) : ThemeColor(0xf2, 0xf2, 0xf7)
        palette.view = dark ? ThemeColor(0, 0, 0) : ThemeColor(0xff, 0xff, 0xff)
        palette.card = dark ? ThemeColor(0x1c, 0x1c, 0x1e) : ThemeColor(0xff, 0xff, 0xff)
        palette.headerbar = palette.card
        palette.text = nil
        return palette
    }

    override func draw(_ rect: CGRect) {
        guard let look, let context = UIGraphicsGetCurrentContext() else { return }
        let design = ThemePreviewView.designSize
        context.scaleBy(x: bounds.width / design.width, y: bounds.height / design.height)
        let dark = drawsDark(look)
        Painter(look: look, palette: palette(for: look, dark: dark), dark: dark).paint()
    }

    private struct Painter {
        let look: ThemeLook
        let palette: ThemePalette
        let dark: Bool

        private var text: ThemeColor { palette.readableText }

        private func fill(_ color: ThemeColor, alpha: Double = 1, _ path: UIBezierPath) {
            UIColor(ThemeInk(color, alpha: alpha)).setFill()
            path.fill()
        }

        private func bar(_ color: ThemeColor, alpha: Double, x: CGFloat, y: CGFloat, width: CGFloat) {
            fill(color, alpha: alpha, UIBezierPath(roundedRect: CGRect(x: x, y: y, width: width, height: 3), cornerRadius: 1.5))
        }

        private func coverColor(_ index: Int) -> ThemeColor {
            let accent = ThemeHSL(palette.accent)
            return ThemeHSL(
                hue: accent.hue + ThemePreviewView.coverHues[index % ThemePreviewView.coverHues.count],
                saturation: 0.42,
                lightness: dark ? 0.44 : 0.62
            ).color
        }

        private func cover(_ index: Int, _ frame: CGRect, alpha: Double = 1, bare: Bool = false) {
            let radius: CGFloat =
                bare
                ? 0
                : {
                    switch look.covers {
                    case .square: 0
                    case .circle: frame.width / 2
                    case .rounded: frame.width * 0.1 * CGFloat(look.corners)
                    }
                }()
            fill(coverColor(index), alpha: alpha, UIBezierPath(roundedRect: frame, cornerRadius: radius))
        }

        private func chips() {
            let radius = 4 * CGFloat(min(look.corners, 1.6))
            fill(palette.accent, alpha: 0.9, UIBezierPath(roundedRect: CGRect(x: 8, y: 12, width: 22, height: 9), cornerRadius: radius))
            for index in 0..<2 {
                let frame = CGRect(x: 34 + CGFloat(index) * 30, y: 12, width: 26, height: 9)
                fill(text, alpha: 0.12, UIBezierPath(roundedRect: frame, cornerRadius: radius))
            }
        }

        private func grid() {
            let side: CGFloat = 31
            for index in 0..<6 {
                let frame = CGRect(
                    x: 8 + CGFloat(index % 3) * (side + 5.5), y: 28 + CGFloat(index / 3) * (side + 15), width: side,
                    height: side
                )
                cover(index, frame)
                bar(text, alpha: 0.55, x: frame.minX, y: frame.maxY + 3.5, width: side * 0.8)
                bar(text, alpha: 0.26, x: frame.minX, y: frame.maxY + 8.5, width: side * 0.5)
            }
        }

        private func wall() {
            let side = ThemePreviewView.designSize.width / 3
            for index in 0..<9 {
                let frame = CGRect(x: CGFloat(index % 3) * side, y: 26 + CGFloat(index / 3) * side, width: side + 0.5, height: side + 0.5)
                cover(index, frame, bare: true)
            }
        }

        private func list() {
            for row in 0..<6 {
                let top = 28 + CGFloat(row) * 16
                if row == 1 {
                    let frame = CGRect(x: 5, y: top - 2.5, width: 110, height: 15)
                    fill(palette.accent, alpha: 0.22, UIBezierPath(roundedRect: frame, cornerRadius: 3 * CGFloat(look.corners)))
                }
                cover(row, CGRect(x: 8, y: top, width: 10, height: 10))
                bar(text, alpha: row == 1 ? 0.9 : 0.55, x: 23, y: top + 1, width: 44 + CGFloat(row % 3) * 12)
                bar(text, alpha: 0.24, x: 23, y: top + 6, width: 30)
            }
        }

        private func carousel() {
            let big: CGFloat = 62
            let middle = ThemePreviewView.designSize.width / 2
            cover(2, CGRect(x: middle - big / 2 - 50, y: 40, width: 44, height: 44), alpha: 0.6)
            cover(3, CGRect(x: middle + big / 2 + 6, y: 40, width: 44, height: 44), alpha: 0.6)
            cover(0, CGRect(x: middle - big / 2, y: 31, width: big, height: big))
            bar(text, alpha: 0.75, x: middle - 28, y: 101, width: 56)
            bar(text, alpha: 0.3, x: middle - 18, y: 107, width: 36)
        }

        private func player() {
            let size = ThemePreviewView.designSize
            let radius = 7 * CGFloat(min(look.corners, 1.6))
            let frame = CGRect(x: 7, y: size.height - 30, width: size.width - 14, height: 20)
            fill(palette.card, UIBezierPath(roundedRect: frame, cornerRadius: radius))
            fill(text, alpha: 0.1, UIBezierPath(roundedRect: frame, cornerRadius: radius))
            fill(palette.accent, UIBezierPath(ovalIn: CGRect(x: 14, y: frame.midY - 4, width: 8, height: 8)))
            bar(text, alpha: 0.6, x: 28, y: frame.midY - 4, width: 40)
            bar(text, alpha: 0.28, x: 28, y: frame.midY + 1.5, width: 26)
            cover(1, CGRect(x: frame.maxX - 18, y: frame.minY + 3, width: 14, height: 14))
        }

        func paint() {
            let size = ThemePreviewView.designSize
            let outline = UIBezierPath(
                roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 12 * CGFloat(min(look.corners, 1.6))
            )
            outline.addClip()
            fill(look.albums == .list ? palette.view : palette.window, UIBezierPath(rect: CGRect(origin: .zero, size: size)))
            switch look.albums {
            case .grid: grid()
            case .wall: wall()
            case .list: list()
            case .carousel: carousel()
            }
            chips()
            player()
        }
    }
}
