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
        case .system: return String(localized: "System")
        case .light: return String(localized: "Light")
        case .dark: return String(localized: "Dark")
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .system: return "settings.appearance.system"
        case .light: return "settings.appearance.light"
        case .dark: return "settings.appearance.dark"
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

    /// Applies the light or dark choice to every window, crossfading unless
    /// Reduce Motion is on. A theme drawn for one mode keeps that mode, which
    /// `AppTheme` decides.
    static func apply(_ appearance: AppAppearance = .current, animated: Bool = false) {
        AppTheme.shared.apply(animated: animated)
    }
}
