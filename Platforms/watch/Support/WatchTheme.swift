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

    /// Blue is the watch's own sky-to-violet pair, as it always was; any other
    /// accent from the phone runs from its dark variant into a neighbouring,
    /// deeper hue.
    private static var pair: (accent: Color, secondary: Color) {
        let choice = WatchAccent.shared.choice
        guard choice != .blue else {
            return (Color(red: 0.45, green: 0.78, blue: 1.0), Color(red: 0.62, green: 0.51, blue: 1.0))
        }
        let base = UIColor(
            red: CGFloat((choice.dark >> 16) & 0xFF) / 255,
            green: CGFloat((choice.dark >> 8) & 0xFF) / 255,
            blue: CGFloat(choice.dark & 0xFF) / 255,
            alpha: 1
        )
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        base.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        let secondary = Color(
            hue: (hue + 0.06).truncatingRemainder(dividingBy: 1),
            saturation: min(1, saturation * 1.05),
            brightness: brightness * 0.85
        )
        return (Color(uiColor: base), secondary)
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
