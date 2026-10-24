#if targetEnvironment(simulator)
import CoreGraphics
import FlaccyCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Procedural, wholly invented album covers for the Simulator's seeded
/// catalog. The seeded WAV files carry no tags, so the library store asks this
/// type for artwork at scan time; nothing here reproduces or references any
/// real-world cover.
enum SampleArtwork {

    private static let side = 400
    private static let cache = CoverCache()

    /// Returns `items` with a generated cover on every item that has none,
    /// keyed by album title so a whole album shares one image.
    static func filling(_ items: [MediaItem]) -> [MediaItem] {
        items.map { item in
            guard item.artworkData == nil, let cover = cover(forAlbum: item.albumTitle) else { return item }
            return MediaItem(
                relativePath: item.relativePath,
                title: item.title,
                artist: item.artist,
                albumTitle: item.albumTitle,
                albumArtist: item.albumArtist,
                trackNumber: item.trackNumber,
                duration: item.duration,
                artworkData: cover
            )
        }
    }

    static func cover(forAlbum title: String) -> Data? {
        cache.data(for: title) { render(design(for: title)) }
    }

    private struct Design {
        let top: CGColor
        let bottom: CGColor
        let accent: CGColor
        let motif: Int
    }

    private static func rgb(_ hex: UInt32) -> CGColor {
        CGColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }

    private static func design(top: UInt32, bottom: UInt32, accent: UInt32, motif: Int) -> Design {
        Design(top: rgb(top), bottom: rgb(bottom), accent: rgb(accent), motif: motif)
    }

    /// The seeded catalog keeps the look of its iPhone covers; any other album
    /// title falls back to a palette and motif chosen by hashing the title.
    private static func design(for albumTitle: String) -> Design {
        switch albumTitle {
        case "Parallax Hours": return design(top: 0x2B1A46, bottom: 0x0C0714, accent: 0xFF6B9D, motif: 0)
        case "Aurorae": return design(top: 0x0E3B4A, bottom: 0x061318, accent: 0x6FE3C8, motif: 4)
        case "Paper Cities": return design(top: 0x4A2C12, bottom: 0x140A05, accent: 0xFFB24A, motif: 1)
        case "Ember & Ash": return design(top: 0x45162A, bottom: 0x14060C, accent: 0xFF8FA3, motif: 5)
        case "Signal Bloom": return design(top: 0x14235C, bottom: 0x060A18, accent: 0x5FA8FF, motif: 2)
        case "Cassini": return design(top: 0x2E1550, bottom: 0x0B0518, accent: 0xC79BFF, motif: 6)
        case "Lantern Year": return design(top: 0x3A2E14, bottom: 0x110D06, accent: 0xE6C36F, motif: 7)
        case "Field Lines": return design(top: 0x1B2E46, bottom: 0x090E16, accent: 0x7FA6FF, motif: 8)
        default: return hashedDesign(for: albumTitle)
        }
    }

    private static func hashedDesign(for albumTitle: String) -> Design {
        let palettes: [(UInt32, UInt32, UInt32)] = [
            (0x2B1A46, 0x0C0714, 0xFF6B9D), (0x0E3B4A, 0x061318, 0x6FE3C8), (0x4A2C12, 0x140A05, 0xFFB24A),
            (0x14235C, 0x060A18, 0x5FA8FF), (0x2E1550, 0x0B0518, 0xC79BFF), (0x123A2E, 0x05120D, 0x8FE6C0),
        ]
        let hash = stableHash(albumTitle)
        let palette = palettes[Int(hash % UInt64(palettes.count))]
        return design(top: palette.0, bottom: palette.1, accent: palette.2, motif: Int((hash >> 8) % 9))
    }

    /// FNV-1a: `String.hashValue` is seeded per process, which would repaint
    /// every cover differently on each launch.
    private static func stableHash(_ text: String) -> UInt64 {
        text.utf8.reduce(14_695_981_039_346_656_037) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
    }

    private static func render(_ design: Design) -> Data? {
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let extent = CGFloat(side)
        if let wash = CGGradient(colorsSpace: nil, colors: [design.top, design.bottom] as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(wash, start: CGPoint(x: 0, y: extent), end: CGPoint(x: extent, y: 0), options: [])
        }
        drawMotif(design.motif, in: context, size: extent, accent: design.accent)
        drawVignette(in: context, size: extent)
        guard let image = context.makeImage() else { return nil }
        return jpegData(from: image)
    }

    private static func jpegData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private static func drawMotif(_ motif: Int, in context: CGContext, size s: CGFloat, accent: CGColor) {
        context.saveGState()
        context.setStrokeColor(accent)
        context.setFillColor(accent)
        switch motif {
        case 0: drawOrbits(in: context, size: s)
        case 1: drawStripes(in: context, size: s)
        case 2: drawDotGrid(in: context, size: s)
        case 3: drawRidgeline(in: context, size: s)
        case 4: drawWaves(in: context, size: s)
        case 5: drawEclipse(in: context, size: s)
        case 6: drawConcentricSquares(in: context, size: s)
        case 7: drawSunburst(in: context, size: s)
        default: drawRoundedFrames(in: context, size: s)
        }
        context.restoreGState()
    }

    private static func drawOrbits(in context: CGContext, size s: CGFloat) {
        context.setLineWidth(s * 0.006)
        for index in 0..<9 {
            let radius = s * 0.09 * CGFloat(index + 1)
            context.setAlpha(0.85 - CGFloat(index) * 0.07)
            context.strokeEllipse(in: CGRect(x: s * 0.62 - radius, y: s * 0.7 - radius, width: radius * 2, height: radius * 2))
        }
        context.setAlpha(0.95)
        context.fillEllipse(in: CGRect(x: s * 0.62 - s * 0.035, y: s * 0.7 - s * 0.035, width: s * 0.07, height: s * 0.07))
    }

    private static func drawStripes(in context: CGContext, size s: CGFloat) {
        context.setLineWidth(s * 0.045)
        for index in 0..<8 {
            context.setAlpha(0.55 - CGFloat(index) * 0.05)
            let offset = CGFloat(index) * s * 0.14 - s * 0.3
            context.move(to: CGPoint(x: offset, y: 0))
            context.addLine(to: CGPoint(x: offset + s, y: s))
            context.strokePath()
        }
    }

    private static func drawDotGrid(in context: CGContext, size s: CGFloat) {
        let diameter = s * 0.05
        for row in 0..<10 {
            for column in 0..<10 {
                context.setAlpha(0.15 + CGFloat((row + column) % 5) * 0.14)
                context.fillEllipse(in: CGRect(
                    x: s * 0.08 + CGFloat(column) * s * 0.086,
                    y: s * 0.08 + CGFloat(row) * s * 0.086,
                    width: diameter, height: diameter
                ))
            }
        }
    }

    private static func drawRidgeline(in context: CGContext, size s: CGFloat) {
        context.setAlpha(0.85)
        context.move(to: CGPoint(x: 0, y: s * 0.28))
        context.addLine(to: CGPoint(x: s * 0.34, y: s * 0.62))
        context.addLine(to: CGPoint(x: s * 0.6, y: s * 0.4))
        context.addLine(to: CGPoint(x: s, y: s * 0.78))
        context.addLine(to: CGPoint(x: s, y: 0))
        context.addLine(to: CGPoint(x: 0, y: 0))
        context.fillPath()
    }

    private static func drawWaves(in context: CGContext, size s: CGFloat) {
        context.setLineWidth(s * 0.007 + 2)
        for band in 0..<6 {
            context.setAlpha(0.75 - CGFloat(band) * 0.1)
            let base = s * (0.3 + CGFloat(band) * 0.1)
            context.move(to: CGPoint(x: 0, y: base))
            for x in stride(from: 0.0, through: Double(s), by: 4) {
                let y = Double(base) + sin(x / (Double(s) * 0.07) + Double(band)) * Double(s) * 0.05
                context.addLine(to: CGPoint(x: CGFloat(x), y: CGFloat(y)))
            }
            context.strokePath()
        }
    }

    private static func drawEclipse(in context: CGContext, size s: CGFloat) {
        context.setAlpha(0.92)
        context.fillEllipse(in: CGRect(x: s * 0.42, y: s * 0.46, width: s * 0.62, height: s * 0.62))
        context.setBlendMode(.softLight)
        context.fillEllipse(in: CGRect(x: s * 0.1, y: s * 0.08, width: s * 0.3, height: s * 0.3))
    }

    private static func drawConcentricSquares(in context: CGContext, size s: CGFloat) {
        context.setLineWidth(s * 0.006 + 1)
        for index in 0..<7 {
            context.setAlpha(0.6 - CGFloat(index) * 0.06)
            let inset = s * 0.1 + CGFloat(index) * s * 0.06
            context.stroke(CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2))
        }
    }

    private static func drawSunburst(in context: CGContext, size s: CGFloat) {
        context.setLineWidth(s * 0.005 + 1)
        context.setAlpha(0.55)
        let center = CGPoint(x: s * 0.5, y: s * 0.42)
        for index in 0..<28 {
            let angle = Double(index) / 28 * 2 * Double.pi
            context.move(to: center)
            context.addLine(to: CGPoint(x: center.x + CGFloat(cos(angle)) * s, y: center.y + CGFloat(sin(angle)) * s))
            context.strokePath()
        }
        context.setAlpha(1)
        context.fillEllipse(in: CGRect(x: center.x - s * 0.07, y: center.y - s * 0.07, width: s * 0.14, height: s * 0.14))
    }

    private static func drawRoundedFrames(in context: CGContext, size s: CGFloat) {
        context.setLineWidth(s * 0.008 + 1)
        for index in 0..<6 {
            let inset = s * 0.12 + CGFloat(index) * s * 0.07
            context.setAlpha(0.75 - CGFloat(index) * 0.11)
            let frame = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
            context.addPath(CGPath(roundedRect: frame, cornerWidth: s * 0.08, cornerHeight: s * 0.08, transform: nil))
            context.strokePath()
        }
    }

    private static func drawVignette(in context: CGContext, size s: CGFloat) {
        let colors = [
            CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0),
            CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.45),
        ] as CFArray
        guard let shade = CGGradient(colorsSpace: nil, colors: colors, locations: [0.55, 1]) else { return }
        let center = CGPoint(x: s / 2, y: s / 2)
        context.drawRadialGradient(shade, startCenter: center, startRadius: 0, endCenter: center, endRadius: s * 0.75, options: [])
    }
}

/// Remembers each album's rendered cover so a library reload never redraws it.
private final class CoverCache: @unchecked Sendable {

    private var covers: [String: Data] = [:]
    private let gate = NSLock()

    func data(for key: String, make: () -> Data?) -> Data? {
        gate.lock()
        defer { gate.unlock() }
        if let cached = covers[key] { return cached }
        guard let made = make() else { return nil }
        covers[key] = made
        return made
    }
}
#endif
