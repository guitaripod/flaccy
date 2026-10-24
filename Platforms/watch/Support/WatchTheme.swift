import SwiftUI

enum WatchTheme {
    static let accent = Color(red: 0.45, green: 0.78, blue: 1.0)
    static let accentSecondary = Color(red: 0.62, green: 0.51, blue: 1.0)

    static let accentGradient = LinearGradient(
        colors: [accent, accentSecondary],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

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
