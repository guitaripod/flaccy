import AppKit

/// Pure CoreGraphics re-implementation of the iOS RecapShareCardView: a 4:5
/// share card rendered at 3× (1080×1350) without any live view hierarchy, so
/// the output can never be blank.
enum RecapShareCardRenderer {

    static func makeImage(data: RecapData, palette: ArtworkPalette, scale: CGFloat = 3) -> NSImage? {
        let size = CGSize(width: 360, height: 450)
        let pixelSize = CGSize(width: size.width * scale, height: size.height * scale)
        guard let context = CGContext(
            data: nil,
            width: Int(pixelSize.width), height: Int(pixelSize.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return nil }
        context.scaleBy(x: scale, y: scale)

        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics

        drawBackground(context: context, size: size, palette: palette)
        drawContent(size: size, data: data)

        NSGraphicsContext.restoreGraphicsState()
        guard let cgImage = context.makeImage() else { return nil }
        return NSImage(cgImage: cgImage, size: size)
    }

    private static func drawBackground(context: CGContext, size: CGSize, palette: ArtworkPalette) {
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(origin: .zero, size: size))

        let colors = palette.colors
        let first = darken(colors.first ?? .systemIndigo, 0.55)
        let second = darken(colors.count > 2 ? colors[2] : colors.last ?? .systemPurple, 0.7)
        let gradientColors = [first.cgColor, second.cgColor, NSColor.black.cgColor] as CFArray
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: gradientColors, locations: [0, 0.6, 1]
        ) else { return }
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: size.height),
            end: CGPoint(x: size.width, y: 0),
            options: []
        )
    }

    private static func drawContent(size: CGSize, data: RecapData) {
        let margin: CGFloat = 28
        var cursorY = size.height - 32

        cursorY = drawText(
            data.userInfo?.name ?? "Your Recap",
            font: .systemFont(ofSize: 30, weight: .heavy), color: .white,
            x: margin, topY: cursorY
        )
        cursorY = drawText(
            "\(data.period.displayName) \u{00B7} flaccy Recap",
            font: .systemFont(ofSize: 14, weight: .medium),
            color: NSColor.white.withAlphaComponent(0.7),
            x: margin, topY: cursorY - 4
        )
        cursorY -= 18

        let columnWidth = (size.width - margin * 2 - 16) / 2
        let statsTop = cursorY
        _ = drawStat(
            value: RecapFormat.count(data.totalPlays), caption: "PLAYS",
            x: margin, topY: statsTop
        )
        cursorY = drawStat(
            value: RecapFormat.count(data.totalMinutes), caption: "MINUTES",
            x: margin + columnWidth + 16, topY: statsTop
        )
        cursorY -= 18

        cursorY = drawText(
            "TOP ARTISTS", font: .systemFont(ofSize: 13, weight: .bold),
            color: NSColor.white.withAlphaComponent(0.6),
            x: margin, topY: cursorY
        )
        cursorY -= 6
        for (offset, artist) in data.topArtists.prefix(5).enumerated() {
            cursorY = drawText(
                "\(offset + 1)  \(artist.name)",
                font: .systemFont(ofSize: 19, weight: .semibold), color: .white,
                x: margin, topY: cursorY, maxWidth: size.width - margin * 2
            ) - 4
        }

        drawText(
            "flaccy \u{00B7} Recap", font: .systemFont(ofSize: 12, weight: .semibold),
            color: NSColor.white.withAlphaComponent(0.6),
            x: margin, topY: 28 + 16
        )
        drawPersonaPill(data.persona, x: margin, bottomY: 28 + 28)
    }

    @discardableResult
    private static func drawText(
        _ text: String, font: NSFont, color: NSColor, x: CGFloat, topY: CGFloat, maxWidth: CGFloat = 320
    ) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let string = text as NSString
        var textSize = string.size(withAttributes: attributes)
        textSize.width = min(textSize.width, maxWidth)
        string.draw(
            in: CGRect(x: x, y: topY - textSize.height, width: maxWidth, height: textSize.height),
            withAttributes: attributes
        )
        return topY - textSize.height
    }

    private static func drawStat(value: String, caption: String, x: CGFloat, topY: CGFloat) -> CGFloat {
        var y = drawText(value, font: .systemFont(ofSize: 44, weight: .heavy), color: .white, x: x, topY: topY)
        y = drawText(
            caption, font: .systemFont(ofSize: 12, weight: .bold),
            color: NSColor.white.withAlphaComponent(0.55), x: x, topY: y
        )
        return y
    }

    private static func drawPersonaPill(_ persona: String, x: CGFloat, bottomY: CGFloat) {
        let font = NSFont.systemFont(ofSize: 15, weight: .bold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let text = persona as NSString
        let textSize = text.size(withAttributes: attributes)
        let pillRect = CGRect(x: x, y: bottomY, width: textSize.width + 32, height: 34)
        let path = NSBezierPath(roundedRect: pillRect, xRadius: 16, yRadius: 16)
        NSColor.white.withAlphaComponent(0.18).setFill()
        path.fill()
        text.draw(
            at: CGPoint(x: pillRect.minX + 16, y: pillRect.midY - textSize.height / 2),
            withAttributes: attributes
        )
    }

    private static func darken(_ color: NSColor, _ factor: CGFloat) -> NSColor {
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgb.getRed(&r, green: &g, blue: &b, alpha: &a)
        return NSColor(red: r * factor, green: g * factor, blue: b * factor, alpha: 1)
    }
}
