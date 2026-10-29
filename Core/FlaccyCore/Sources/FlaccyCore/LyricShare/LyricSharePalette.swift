import Foundation

/// An sRGB colour, each channel 0 to 1.
public struct LyricShareColor: Sendable, Equatable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    /// WCAG relative luminance.
    public var luminance: Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG contrast ratio, 1 to 21.
    public func contrast(with other: LyricShareColor) -> Double {
        let lighter = max(luminance, other.luminance)
        let darker = min(luminance, other.luminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// Hue 0 to 1, saturation and lightness 0 to 1.
    public var hsl: (hue: Double, saturation: Double, lightness: Double) {
        let high = max(red, green, blue)
        let low = min(red, green, blue)
        let lightness = (high + low) / 2
        let delta = high - low
        guard delta > 1e-9 else { return (0, 0, lightness) }
        let saturation = delta / (1 - abs(2 * lightness - 1))
        var hue: Double
        if high == red {
            hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
        } else if high == green {
            hue = (blue - red) / delta + 2
        } else {
            hue = (red - green) / delta + 4
        }
        hue /= 6
        if hue < 0 { hue += 1 }
        return (hue, min(saturation, 1), lightness)
    }

    public init(hue: Double, saturation: Double, lightness: Double) {
        let chroma = (1 - abs(2 * lightness - 1)) * saturation
        let sector = hue * 6
        let second = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let (r, g, b): (Double, Double, Double)
        switch sector {
        case ..<1: (r, g, b) = (chroma, second, 0)
        case ..<2: (r, g, b) = (second, chroma, 0)
        case ..<3: (r, g, b) = (0, chroma, second)
        case ..<4: (r, g, b) = (0, second, chroma)
        case ..<5: (r, g, b) = (second, 0, chroma)
        default: (r, g, b) = (chroma, 0, second)
        }
        let match = lightness - chroma / 2
        self.init(
            red: min(max(r + match, 0), 1),
            green: min(max(g + match, 0), 1),
            blue: min(max(b + match, 0), 1)
        )
    }

    /// How colourful the colour looks: HSL chroma.
    var chroma: Double {
        max(red, green, blue) - min(red, green, blue)
    }
}

/// The colours a clip is painted in. The background runs from `background`
/// at the top to `backgroundDeep` at the bottom; with `backdrop` above zero
/// the blurred artwork is laid over it at that opacity. `ink` is the text,
/// `accent` the visualizer. Mirrored in Rust as
/// `linux/shared/src/lyric_share/palette.rs`.
public struct LyricSharePalette: Sendable, Equatable {
    public var background: LyricShareColor
    public var backgroundDeep: LyricShareColor
    public var ink: LyricShareColor
    public var accent: LyricShareColor
    public var backdrop: Double

    public init(
        background: LyricShareColor, backgroundDeep: LyricShareColor,
        ink: LyricShareColor, accent: LyricShareColor, backdrop: Double
    ) {
        self.background = background
        self.backgroundDeep = backgroundDeep
        self.ink = ink
        self.accent = accent
        self.backdrop = backdrop
    }

    public static let white = LyricShareColor(hex: 0xFFFFFF)
    public static let nearBlack = LyricShareColor(hex: 0x121212)
    /// Below this chroma the artwork is treated as grey and lends no hue.
    public static let greyChroma = 0.08
    public static let fallback = LyricShareColor(hex: 0x3A3A46)

    /// Builds a theme's palette from colours sampled across the artwork, a
    /// small downscale is plenty. With no samples the artwork themes fall
    /// back to a neutral slate.
    public static func make(theme: LyricShareTheme, samples: [LyricShareColor]) -> LyricSharePalette {
        let average = mean(samples) ?? fallback
        let vivid = samples.enumerated().max { left, right in
            if left.element.chroma != right.element.chroma {
                return left.element.chroma < right.element.chroma
            }
            return left.offset > right.offset
        }?.element ?? average
        let tone = vivid.hsl
        let grey = vivid.chroma < greyChroma
        let accentSaturation = min(max(tone.saturation, 0.45), 0.9)
        let accentOnDark = grey
            ? LyricShareColor(hex: 0xF2F2F2)
            : LyricShareColor(hue: tone.hue, saturation: accentSaturation, lightness: 0.64)
        switch theme {
        case .artwork:
            let base = average.hsl
            let saturation = min(base.saturation, 0.5)
            return LyricSharePalette(
                background: LyricShareColor(hue: base.hue, saturation: saturation, lightness: 0.18),
                backgroundDeep: LyricShareColor(hue: base.hue, saturation: saturation, lightness: 0.07),
                ink: white,
                accent: accentOnDark,
                backdrop: 0.6
            )
        case .vivid:
            let saturation = grey ? 0 : min(max(tone.saturation, 0.55), 0.95)
            let background = LyricShareColor(hue: tone.hue, saturation: saturation, lightness: 0.46)
            let ink = readableInk(on: background)
            return LyricSharePalette(
                background: background,
                backgroundDeep: LyricShareColor(hue: deepHue(tone.hue), saturation: saturation, lightness: 0.32),
                ink: ink,
                accent: ink,
                backdrop: 0
            )
        case .dark:
            return LyricSharePalette(
                background: LyricShareColor(hex: 0x141416),
                backgroundDeep: LyricShareColor(hex: 0x000000),
                ink: white,
                accent: accentOnDark,
                backdrop: 0
            )
        case .light:
            let accent = grey
                ? nearBlack
                : LyricShareColor(hue: tone.hue, saturation: accentSaturation, lightness: 0.36)
            return LyricSharePalette(
                background: LyricShareColor(hex: 0xF5F1E8),
                backgroundDeep: LyricShareColor(hex: 0xE7E0D2),
                ink: nearBlack,
                accent: accent,
                backdrop: 0
            )
        }
    }

    /// The vivid gradient's foot turns a little toward red, so a yellow
    /// deepens into amber rather than olive.
    static func deepHue(_ hue: Double) -> Double {
        let turned = hue - 0.04
        return turned < 0 ? turned + 1 : turned
    }

    /// White or near black, whichever reads better on `background`.
    public static func readableInk(on background: LyricShareColor) -> LyricShareColor {
        background.contrast(with: white) >= background.contrast(with: nearBlack) ? white : nearBlack
    }

    private static func mean(_ samples: [LyricShareColor]) -> LyricShareColor? {
        guard !samples.isEmpty else { return nil }
        let count = Double(samples.count)
        return LyricShareColor(
            red: samples.reduce(0) { $0 + $1.red } / count,
            green: samples.reduce(0) { $0 + $1.green } / count,
            blue: samples.reduce(0) { $0 + $1.blue } / count
        )
    }
}
