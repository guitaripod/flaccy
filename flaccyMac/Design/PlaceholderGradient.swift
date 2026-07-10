import AppKit

/// Deterministic missing-artwork gradient shared across the whole Flaccy
/// family: FNV-1a 64-bit hash of the seed selects the hue, so the same album
/// renders the same colors on iPhone, Apple Watch, and the Mac.
enum PlaceholderGradient {

    static func colors(seed: String) -> (base: NSColor, second: NSColor) {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in seed.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
        let hue = CGFloat(hash % 360) / 360
        let base = NSColor(hue: hue, saturation: 0.45, brightness: 0.55, alpha: 1)
        let second = NSColor(
            hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.5, brightness: 0.35, alpha: 1
        )
        return (base, second)
    }

    static func layer(seed: String) -> CAGradientLayer {
        let (base, second) = colors(seed: seed)
        let gradient = CAGradientLayer()
        gradient.colors = [base.cgColor, second.cgColor]
        gradient.startPoint = CGPoint(x: 0, y: 1)
        gradient.endPoint = CGPoint(x: 1, y: 0)
        return gradient
    }

    static func image(seed: String, size: CGSize) -> NSImage {
        let (base, second) = colors(seed: seed)
        return NSImage(size: size, flipped: false) { rect in
            guard let gradient = NSGradient(colors: [base, second]) else { return false }
            gradient.draw(in: rect, angle: -45)
            return true
        }
    }
}
