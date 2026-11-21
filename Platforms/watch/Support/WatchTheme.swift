import FlaccyCore
import SwiftUI
import UIKit

enum WatchTheme {
    static var accent: Color { pair.accent }
    static var accentSecondary: Color { pair.secondary }

    static var accentGradient: LinearGradient {
        LinearGradient(
            colors: [accent, accentSecondary],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// The theme the phone has on, when it is not Flaccy's own.
    private static var worn: ThemeWatchLook? {
        WatchAccent.shared.look.flatMap { $0.isOwnLook ? nil : $0 }
    }

    /// Blue is the watch's own sky-to-violet pair, as it always was; a theme's
    /// accent, or any other accent from the phone, runs from its dark variant
    /// into a neighbouring, deeper hue.
    private static var pair: (accent: Color, secondary: Color) {
        let choice = WatchAccent.shared.choice
        let packed: UInt32
        if let worn {
            packed = worn.accent
        } else if choice == .blue {
            return (Color(red: 0.45, green: 0.78, blue: 1.0), Color(red: 0.62, green: 0.51, blue: 1.0))
        } else {
            packed = choice.dark
        }
        let base = uiColor(packed)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        base.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        let secondary = Color(
            hue: (hue + 0.06).truncatingRemainder(dividingBy: 1),
            saturation: min(1, saturation * 1.05),
            brightness: brightness * 0.85
        )
        return (Color(uiColor: base), secondary)
    }

    private static func uiColor(_ packed: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((packed >> 16) & 0xFF) / 255,
            green: CGFloat((packed >> 8) & 0xFF) / 255,
            blue: CGFloat(packed & 0xFF) / 255,
            alpha: 1
        )
    }

    /// The color text is drawn in: the theme's own when it states one,
    /// otherwise the system's.
    static var text: Color {
        worn?.text.map { Color(uiColor: uiColor($0)) } ?? .primary
    }

    /// The system design the theme's typeface stands for on the wrist, or
    /// nothing for the system's own.
    static var fontDesign: Font.Design? {
        switch worn?.bodyFace ?? worn?.headingFace {
        case .monospaced: .monospaced
        case .serif: .serif
        case .rounded: .rounded
        case .family, nil: nil
        }
    }

    /// The outline a cover is clipped to: the theme's shape, with `radius`
    /// where the theme leaves covers rounded.
    static func coverShape(radius: CGFloat) -> AnyShape {
        switch worn?.coverShape ?? .rounded {
        case .rounded: AnyShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        case .square: AnyShape(Rectangle())
        case .circle: AnyShape(Circle())
        }
    }

    static func placeholderGradient(seed: String) -> LinearGradient {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in seed.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        let hue = Double(hash % 360) / 360.0
        let base = Color(hue: hue, saturation: 0.45, brightness: 0.55)
        let second = Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.5, brightness: 0.35)
        return LinearGradient(colors: [base, second], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

enum TimeFormat {
    static func string(_ interval: TimeInterval) -> String {
        guard interval.isFinite, interval >= 0 else { return "0:00" }
        let total = Int(interval.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
