import FlaccyCore
import ImageIO
import SwiftUI

extension ArtworkTint {

    func color(brightness: Double) -> Color {
        Color(hue: hue, saturation: saturation, brightness: brightness)
    }

    /// A soft top-to-bottom wash that stays dark enough for white text.
    var gradient: LinearGradient {
        LinearGradient(
            colors: [color(brightness: 0.5), color(brightness: 0.16)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

/// Finds each track's tint once, off the main thread, and remembers it.
actor ArtworkTintCache {

    static let shared = ArtworkTintCache()

    private var tints: [String: ArtworkTint?] = [:]
    private var order: [String] = []
    private static let capacity = 24

    func tint(for item: MediaItem) -> ArtworkTint? {
        if let cached = tints[item.id] { return cached }
        let tint = item.artworkData.flatMap(Self.dominantTint(in:))
        remember(tint, for: item.id)
        return tint
    }

    private func remember(_ tint: ArtworkTint?, for id: String) {
        tints[id] = .some(tint)
        order.append(id)
        if order.count > Self.capacity {
            tints.removeValue(forKey: order.removeFirst())
        }
    }

    private static let sampleSide = ArtworkTint.sampleSide

    /// Downsamples to a swatch the size `ArtworkTint.dominant(inRGBA:)` reads.
    private static func dominantTint(in data: Data) -> ArtworkTint? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 32,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

        var pixels = [UInt8](repeating: 0, count: sampleSide * sampleSide * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: sampleSide,
                height: sampleSide,
                bitsPerComponent: 8,
                bytesPerRow: sampleSide * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: sampleSide, height: sampleSide))
            return true
        }
        guard drawn else { return nil }
        return ArtworkTint.dominant(inRGBA: pixels)
    }
}
