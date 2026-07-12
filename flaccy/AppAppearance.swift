import UIKit

/// The user's global light/dark preference, persisted and applied to every
/// connected window scene. Screens that deliberately force their own style
/// (the player, the listening guide) opt in per–view-controller and are
/// unaffected by this override.
nonisolated enum AppAppearance: Int, CaseIterable {
    case system
    case light
    case dark

    private static let defaultsKey = "flaccy.appearance"

    static var current: AppAppearance {
        get { AppAppearance(rawValue: UserDefaults.standard.integer(forKey: Self.defaultsKey)) ?? .system }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.defaultsKey) }
    }

    var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var symbolName: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.stars.fill"
        }
    }

    var userInterfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: return .unspecified
        case .light: return .light
        case .dark: return .dark
        }
    }
}

@MainActor
enum AppearanceApplier {

    /// Applies the appearance to every window of every connected scene,
    /// crossfading the trait change unless Reduce Motion is on.
    static func apply(_ appearance: AppAppearance = .current, animated: Bool = false) {
        let style = appearance.userInterfaceStyle
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows where window.overrideUserInterfaceStyle != style {
                if animated && !UIAccessibility.isReduceMotionEnabled {
                    UIView.transition(with: window, duration: 0.3, options: .transitionCrossDissolve) {
                        window.overrideUserInterfaceStyle = style
                    }
                } else {
                    window.overrideUserInterfaceStyle = style
                }
            }
        }
    }
}
