import Foundation

/// A color as its red, green and blue bytes, with the arithmetic a theme's
/// palette is worked out by. Mirrored in Rust as
/// `linux/shared/src/theme/color.rs`.
public struct ThemeColor: Hashable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(_ red: UInt8, _ green: UInt8, _ blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static let white = ThemeColor(0xff, 0xff, 0xff)
    public static let nearBlack = ThemeColor(0x11, 0x11, 0x14)

    /// The least contrast a glyph or label needs against the fill it sits on.
    public static let glyphContrast = 3.0

    /// Reads `#rgb` or `#rrggbb`, with or without the `#`.
    public init?(hex text: String) {
        var digits = Substring(text.trimmingCharacters(in: .whitespaces))
        while digits.first == "#" { digits = digits.dropFirst() }
        guard digits.unicodeScalars.allSatisfy({ $0.isASCII && Character($0).isHexDigit }) else { return nil }
        let values = digits.compactMap { $0.hexDigitValue }.map { UInt8($0) }
        switch values.count {
        case 6:
            self.init(values[0] * 16 + values[1], values[2] * 16 + values[3], values[4] * 16 + values[5])
        case 3:
            self.init(values[0] * 17, values[1] * 17, values[2] * 17)
        default:
            return nil
        }
    }

    /// `#rrggbb`, lowercase.
    public var hex: String {
        let digits = Array("0123456789abcdef")
        return "#" + [red, green, blue].map { "\(digits[Int($0 / 16)])\(digits[Int($0 % 16)])" }.joined()
    }

    /// 0xRRGGBB, the form the accent pairs are stored in.
    public var packed: UInt32 {
        UInt32(red) << 16 | UInt32(green) << 8 | UInt32(blue)
    }

    /// Relative luminance, the measure a legible foreground is chosen by.
    public var luminance: Double {
        func channel(_ value: UInt8) -> Double {
            let c = Double(value) / 255.0
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    /// The WCAG contrast ratio between two colors, from 1 to 21.
    public func contrast(with other: ThemeColor) -> Double {
        let (a, b) = (luminance, other.luminance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// The foreground for a fill of this color: white wherever white is
    /// readable on it, near-black on anything lighter.
    public var legibleForeground: ThemeColor {
        ThemeColor.white.contrast(with: self) >= ThemeColor.glyphContrast ? .white : .nearBlack
    }
}

/// A color as hue (degrees), saturation and lightness (0 to 1).
public struct ThemeHSL: Sendable {
    public var hue: Double
    public var saturation: Double
    public var lightness: Double

    public init(hue: Double, saturation: Double, lightness: Double) {
        self.hue = hue
        self.saturation = saturation
        self.lightness = lightness
    }

    public init(_ color: ThemeColor) {
        let r = Double(color.red) / 255.0
        let g = Double(color.green) / 255.0
        let b = Double(color.blue) / 255.0
        let high = max(r, g, b)
        let low = min(r, g, b)
        let lightness = (high + low) / 2.0
        let delta = high - low
        guard delta >= 1e-6 else {
            self.init(hue: 0, saturation: 0, lightness: lightness)
            return
        }
        let saturation = delta / (1.0 - abs(2.0 * lightness - 1.0))
        let hue: Double
        if high == r {
            hue = 60.0 * ThemeHSL.wrapped((g - b) / delta, by: 6.0)
        } else if high == g {
            hue = 60.0 * (((b - r) / delta) + 2.0)
        } else {
            hue = 60.0 * (((r - g) / delta) + 4.0)
        }
        self.init(hue: hue, saturation: saturation, lightness: lightness)
    }

    /// `value` brought into `0 ..< modulus`, as Rust's `rem_euclid` does.
    static func wrapped(_ value: Double, by modulus: Double) -> Double {
        let remainder = value.truncatingRemainder(dividingBy: modulus)
        return remainder < 0 ? remainder + modulus : remainder
    }

    public var color: ThemeColor {
        let c = (1.0 - abs(2.0 * lightness - 1.0)) * saturation
        let sector = ThemeHSL.wrapped(hue, by: 360.0) / 60.0
        let x = c * (1.0 - abs(ThemeHSL.wrapped(sector, by: 2.0) - 1.0))
        let (r1, g1, b1): (Double, Double, Double)
        switch Int(sector) {
        case 0: (r1, g1, b1) = (c, x, 0)
        case 1: (r1, g1, b1) = (x, c, 0)
        case 2: (r1, g1, b1) = (0, c, x)
        case 3: (r1, g1, b1) = (0, x, c)
        case 4: (r1, g1, b1) = (x, 0, c)
        default: (r1, g1, b1) = (c, 0, x)
        }
        let m = lightness - c / 2.0
        func byte(_ value: Double) -> UInt8 {
            UInt8(min(max(((value + m) * 255.0).rounded(), 0), 255))
        }
        return ThemeColor(byte(r1), byte(g1), byte(b1))
    }
}
