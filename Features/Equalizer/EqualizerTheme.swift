import FlaccyCore
import Foundation

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// The equalizer's colours. The accent follows the artwork of whatever is
/// playing, the way the rest of Now Playing does, so the curve takes on the
/// record's colour; teal is reserved for the lossless, bit-perfect promise.
enum EqualizerTheme {

    static let fallbackAccent = PlatformColor(red: 0.93, green: 0.42, blue: 0.65, alpha: 1)
    static let lossless = PlatformColor(red: 0.37, green: 0.83, blue: 0.88, alpha: 1)
    static let caution = PlatformColor(red: 1.0, green: 0.71, blue: 0.33, alpha: 1)
    static let danger = PlatformColor(red: 1.0, green: 0.42, blue: 0.45, alpha: 1)
    static let cut = PlatformColor(red: 0.56, green: 0.64, blue: 1.0, alpha: 1)

    static let bandColors: [PlatformColor] = [
        (1.00, 0.48, 0.56), (1.00, 0.64, 0.36), (0.95, 0.83, 0.36), (0.61, 0.90, 0.39), (0.31, 0.88, 0.69),
        (0.29, 0.78, 0.94), (0.49, 0.61, 1.00), (0.71, 0.54, 1.00), (0.91, 0.52, 0.94), (1.00, 0.52, 0.75),
    ].map { PlatformColor(red: $0.0, green: $0.1, blue: $0.2, alpha: 1) }

    static func bandColor(_ index: Int) -> PlatformColor {
        bandColors[((index % bandColors.count) + bandColors.count) % bandColors.count]
    }

    /// The most vivid colour in the palette, lifted until it reads on a dark
    /// surface. A palette of greys falls back to the house pink.
    static func accent(from palette: ArtworkPalette?) -> PlatformColor {
        guard let palette else { return fallbackAccent }
        var best: (score: CGFloat, hue: CGFloat, saturation: CGFloat, brightness: CGFloat)?
        for color in palette.colors {
            var hue: CGFloat = 0
            var saturation: CGFloat = 0
            var brightness: CGFloat = 0
            var alpha: CGFloat = 0
            #if canImport(UIKit)
            color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
            #else
            (color.usingColorSpace(.deviceRGB) ?? color).getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
            #endif
            let score = saturation * (0.4 + brightness)
            if best == nil || score > best!.score {
                best = (score, hue, saturation, brightness)
            }
        }
        guard let best, best.saturation > 0.18 else { return fallbackAccent }
        return PlatformColor(
            hue: best.hue,
            saturation: min(max(best.saturation, 0.45), 0.85),
            brightness: max(best.brightness, 0.88),
            alpha: 1
        )
    }
}
