import UIKit
import simd

struct ArtworkPalette: Equatable {
    let colors: [UIColor]

    var simdColors: [SIMD4<Float>] {
        colors.map { color in
            var r: CGFloat = 0
            var g: CGFloat = 0
            var b: CGFloat = 0
            var a: CGFloat = 0
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
            return SIMD4<Float>(Float(r), Float(g), Float(b), 1)
        }
    }

    var dominant: UIColor { colors.first ?? .systemIndigo }
}

enum ArtworkPaletteExtractor {

    private static let cache = NSCache<NSString, Box>()
    private static let queue = DispatchQueue(label: "com.flaccy.palette", qos: .utility)

    private final class Box {
        let palette: ArtworkPalette
        init(_ palette: ArtworkPalette) { self.palette = palette }
    }

    static func palette(
        for image: UIImage?,
        cacheKey: String,
        fallbackSeed: String,
        completion: @escaping (ArtworkPalette) -> Void
    ) {
        if let cached = cache.object(forKey: cacheKey as NSString) {
            completion(cached.palette)
            return
        }
        guard let image else {
            let fallback = fallbackPalette(seed: fallbackSeed)
            completion(fallback)
            return
        }
        queue.async {
            let palette = extract(from: image) ?? fallbackPalette(seed: fallbackSeed)
            cache.setObject(Box(palette), forKey: cacheKey as NSString)
            DispatchQueue.main.async { completion(palette) }
        }
    }

    /// Derives a deterministic four-color palette from a string hash so trackless or
    /// artwork-less states still produce a stable, colorful backdrop.
    static func fallbackPalette(seed: String) -> ArtworkPalette {
        var hash: UInt64 = 5381
        for byte in seed.utf8 {
            hash = (hash &* 33) &+ UInt64(byte)
        }
        let baseHue = CGFloat(hash % 360) / 360
        let offsets: [CGFloat] = [0, 0.09, 0.5, 0.16]
        let colors = offsets.enumerated().map { index, offset in
            UIColor(
                hue: (baseHue + offset).truncatingRemainder(dividingBy: 1),
                saturation: index == 2 ? 0.45 : 0.65,
                brightness: index.isMultiple(of: 2) ? 0.62 : 0.42,
                alpha: 1
            )
        }
        return ArtworkPalette(colors: colors)
    }

    /// Downsamples the artwork to a tiny bitmap and runs a short k-means pass (k = 4)
    /// so extraction stays cheap enough for the utility queue on every track change.
    private static func extract(from image: UIImage) -> ArtworkPalette? {
        guard let pixels = downsampledPixels(from: image, dimension: 24), !pixels.isEmpty else {
            AppLogger.warning("Palette extraction failed to downsample artwork", category: .ui)
            return nil
        }
        var centroids = seedCentroids(from: pixels)
        var assignments = [Int](repeating: 0, count: pixels.count)
        for _ in 0..<6 {
            for (index, pixel) in pixels.enumerated() {
                var best = 0
                var bestDistance = Float.greatestFiniteMagnitude
                for (centroidIndex, centroid) in centroids.enumerated() {
                    let distance = simd_distance_squared(pixel, centroid)
                    if distance < bestDistance {
                        bestDistance = distance
                        best = centroidIndex
                    }
                }
                assignments[index] = best
            }
            var sums = [SIMD3<Float>](repeating: .zero, count: centroids.count)
            var counts = [Int](repeating: 0, count: centroids.count)
            for (index, pixel) in pixels.enumerated() {
                sums[assignments[index]] += pixel
                counts[assignments[index]] += 1
            }
            for index in centroids.indices where counts[index] > 0 {
                centroids[index] = sums[index] / Float(counts[index])
            }
        }
        var weighted = centroids.enumerated().map { index, centroid in
            (centroid, assignments.count(where: { $0 == index }))
        }
        weighted.sort { $0.1 > $1.1 }
        let colors = weighted.map { entry in
            UIColor(
                red: CGFloat(entry.0.x),
                green: CGFloat(entry.0.y),
                blue: CGFloat(entry.0.z),
                alpha: 1
            )
        }
        return ArtworkPalette(colors: colors)
    }

    private static func seedCentroids(from pixels: [SIMD3<Float>]) -> [SIMD3<Float>] {
        let stride = max(1, pixels.count / 4)
        return (0..<4).map { pixels[min($0 * stride, pixels.count - 1)] }
    }

    private static func downsampledPixels(from image: UIImage, dimension: Int) -> [SIMD3<Float>]? {
        guard let cgImage = image.cgImage else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = dimension * 4
        var raw = [UInt8](repeating: 0, count: bytesPerRow * dimension)
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: &raw,
            width: dimension,
            height: dimension,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }
        context.interpolationQuality = .low
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: dimension, height: dimension))
        var pixels: [SIMD3<Float>] = []
        pixels.reserveCapacity(dimension * dimension)
        for y in 0..<dimension {
            for x in 0..<dimension {
                let offset = y * bytesPerRow + x * 4
                pixels.append(
                    SIMD3<Float>(
                        Float(raw[offset]) / 255,
                        Float(raw[offset + 1]) / 255,
                        Float(raw[offset + 2]) / 255
                    )
                )
            }
        }
        return pixels
    }
}
