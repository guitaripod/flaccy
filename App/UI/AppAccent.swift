import FlaccyCore
import UIKit

/// The accent the person picked in Settings, persisted and applied as the tint
/// of every window, so every control, highlight and progress line that follows
/// the tint follows it too.
nonisolated enum AppAccent {

    static var current: AccentChoice {
        get { AccentChoice(id: UserDefaults.standard.string(forKey: AccentChoice.defaultsKey)) }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: AccentChoice.defaultsKey) }
    }
}

extension AccentChoice {

    var displayName: String {
        switch self {
        case .blue: String(localized: "Blue")
        case .rosewater: String(localized: "Rosewater")
        case .aurora: String(localized: "Aurora")
        case .nocturne: String(localized: "Nocturne")
        case .verdant: String(localized: "Verdant")
        case .sunset: String(localized: "Sunset")
        case .mono: String(localized: "Graphite")
        }
    }

    /// The light and dark pair as one color that follows the appearance.
    var color: UIColor {
        if self == .blue { return .systemBlue }
        let onLight = UIColor(rgb: light)
        let onDark = UIColor(rgb: dark)
        return UIColor { $0.userInterfaceStyle == .dark ? onDark : onLight }
    }

    /// What a window's `tintColor` is set to: nothing for Blue, which leaves
    /// the system default exactly as every earlier release had it.
    var windowTint: UIColor? {
        self == .blue ? nil : color
    }
}

private extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}

@MainActor
enum AccentApplier {

    /// Tints every window of every connected scene, crossfading unless Reduce
    /// Motion is on.
    static func apply(_ accent: AccentChoice = AppAccent.current, animated: Bool = false) {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                if animated && !UIAccessibility.isReduceMotionEnabled {
                    UIView.transition(with: window, duration: 0.3, options: .transitionCrossDissolve) {
                        window.tintColor = accent.windowTint
                    }
                } else {
                    window.tintColor = accent.windowTint
                }
            }
        }
        NotificationCenter.default.post(name: AppAccent.didChange, object: nil)
    }
}

extension AppAccent {
    static let didChange = Notification.Name("FlaccyAccentDidChange")
}
