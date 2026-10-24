import Foundation

/// The colour a cover is mostly made of, reduced to the hue and saturation a
/// background wash needs.
public struct ArtworkTint: Sendable, Equatable {

    public let hue: Double
    public let saturation: Double

    public init(hue: Double, saturation: Double) {
        self.hue = hue
        self.saturation = saturation
    }

    /// Side length of the square swatch callers should downsample a cover to.
    public static let sampleSide = 16

    private static let hueBins = 12

    /// Reads premultiplied RGBA pixels, buckets them by hue weighted by how
    /// vivid and bright they are, and answers with the heaviest bucket, so a
    /// mostly-grey cover with one red object reads red rather than muddy.
    /// An all-grey cover answers saturation 0; an all-dark one answers nil.
    public static func dominant(inRGBA pixels: [UInt8]) -> ArtworkTint? {
        var weight = [Double](repeating: 0, count: hueBins)
        var hueSum = [Double](repeating: 0, count: hueBins)
        var saturationSum = [Double](repeating: 0, count: hueBins)
        var greyWeight = 0.0

        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let (hue, saturation, brightness) = hsb(
                red: Double(pixels[offset]) / 255,
                green: Double(pixels[offset + 1]) / 255,
                blue: Double(pixels[offset + 2]) / 255
            )
            guard brightness > 0.08 else { continue }
            guard saturation > 0.12 else {
                greyWeight += brightness
                continue
            }
            let bin = min(hueBins - 1, Int(hue * Double(hueBins)))
            let pixelWeight = saturation * (0.3 + brightness)
            weight[bin] += pixelWeight
            hueSum[bin] += hue * pixelWeight
            saturationSum[bin] += saturation * pixelWeight
        }

        guard let best = weight.indices.max(by: { weight[$0] < weight[$1] }), weight[best] > 0 else {
            return greyWeight > 0 ? ArtworkTint(hue: 0, saturation: 0) : nil
        }
        let meanSaturation = saturationSum[best] / weight[best]
        return ArtworkTint(hue: hueSum[best] / weight[best], saturation: min(0.85, max(0.35, meanSaturation)))
    }

    private static func hsb(red: Double, green: Double, blue: Double) -> (Double, Double, Double) {
        let high = max(red, green, blue)
        let low = min(red, green, blue)
        let delta = high - low
        guard high > 0, delta > 0 else { return (0, 0, high) }
        let hue: Double
        switch high {
        case red: hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
        case green: hue = (blue - red) / delta + 2
        default: hue = (red - green) / delta + 4
        }
        let normalized = (hue / 6).truncatingRemainder(dividingBy: 1)
        return (normalized < 0 ? normalized + 1 : normalized, delta / high, high)
    }
}
