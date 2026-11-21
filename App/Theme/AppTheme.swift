import FlaccyCore
import MidgarCore
import UIKit

/// The theme the app is wearing: which one, with which colors and variant,
/// and what the person has chosen for themselves over it. It turns that into
/// the palettes, faces and shapes the rest of the app draws with, applies
/// them to every window at once, and tells whoever lays out by the look.
///
/// Flaccy's own theme is the system's look with the accent picked in Settings,
/// exactly as before themes existed; every other theme paints its own
/// surfaces and text.
@MainActor
final class AppTheme {

    static let shared = AppTheme()

    /// Posted after the look changed and was applied.
    static let didChange = Notification.Name("FlaccyThemeDidChange")

    private(set) var library: ThemeLibrary
    private(set) var wardrobe: ThemeWardrobe
    private(set) var look: ThemeLook
    private var epoch = 0

    /// Where the person's own themes live: a folder they can reach in Files.
    static var themesDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Themes")
    }

    private init() {
        library = ThemeLibrary(themesDirectory: AppTheme.themesDirectory)
        var stored = ThemeWardrobe(stored: UserDefaults.standard.data(forKey: ThemeWardrobe.storageKey))
        #if DEBUG
        AppTheme.applyLaunchOverride(to: &stored)
        #endif
        if stored.wornPackID == ThemeLibrary.defaultID {
            stored.scheme = AppTheme.schemeID(for: AppAccent.current)
        }
        wardrobe = stored
        look = stored.look(in: library)
    }

    #if DEBUG
    /// `FLACCY_THEME=pack[/scheme[/variant]]` and `FLACCY_ALBUMS_VIEW` dress a
    /// debug launch without touching Settings, for captures.
    private static func applyLaunchOverride(to wardrobe: inout ThemeWardrobe) {
        let environment = ProcessInfo.processInfo.environment
        if let theme = environment["FLACCY_THEME"], !theme.isEmpty {
            let parts = theme.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            wardrobe.wear(pack: parts[0])
            if parts.count > 1 { wardrobe.wear(scheme: parts[1]) }
            if parts.count > 2 { wardrobe.wear(variant: parts[2]) }
        }
        if let view = environment["FLACCY_ALBUMS_VIEW"] { wardrobe.show(albumsAs: view) }
        if let covers = environment["FLACCY_COVERS"] { wardrobe.covers = covers }
        if let corners = environment["FLACCY_CORNERS"] { wardrobe.corners = corners }
        if let font = environment["FLACCY_FONT"] { wardrobe.font = font }
    }
    #endif

    /// The scheme of Flaccy's own theme that stands for an accent: its id,
    /// with Blue standing where Linux has Adaptive.
    static func schemeID(for accent: AccentChoice) -> String {
        accent == .blue ? "adaptive" : accent.rawValue
    }

    /// Whether the worn theme is Flaccy's own, whose surfaces and text are
    /// the system's.
    var isSystemLook: Bool { look.pack.id == ThemeLibrary.defaultID }

    /// The accent Flaccy's own theme wears, as the scheme that is on.
    var accent: AccentChoice { AccentChoice(id: look.wornScheme.id) }

    /// The one place the look changes: `change` rewrites what is worn or what
    /// the person chose, which is then saved and applied.
    func edit(animated: Bool = true, _ change: (inout ThemeWardrobe) -> Void) {
        var next = wardrobe
        change(&next)
        guard next != wardrobe else { return }
        wardrobe = next
        UserDefaults.standard.set(next.stored, forKey: ThemeWardrobe.storageKey)
        if next.wornPackID == ThemeLibrary.defaultID {
            AppAccent.current = AccentChoice(id: next.scheme)
        }
        resolve()
        apply(animated: animated)
        MidgarLog.info(
            "Theme \(look.pack.id) / \(look.wornScheme.id) / \(look.wornVariant?.id ?? "-"), albums as \(look.albums.id)",
            category: .ui
        )
    }

    /// The accent was picked in Settings, which is the color scheme of
    /// Flaccy's own theme.
    func accentChanged(animated: Bool) {
        guard wardrobe.wornPackID == ThemeLibrary.defaultID else { return }
        let scheme = AppTheme.schemeID(for: AppAccent.current)
        guard wardrobe.scheme != scheme else {
            apply(animated: animated)
            return
        }
        edit(animated: animated) { $0.wear(scheme: scheme) }
    }

    /// Reads the themes folder again, for a theme added, changed or removed
    /// while the app was away.
    func reloadLibrary() {
        let reloaded = ThemeLibrary(themesDirectory: AppTheme.themesDirectory)
        let unchanged = reloaded.packs == library.packs && reloaded.problems == library.problems
        guard !unchanged else { return }
        library = reloaded
        resolve()
        apply(animated: false)
    }

    private func resolve() {
        look = wardrobe.look(in: library)
    }

    /// The style a window takes: the theme's own mode when it is drawn for
    /// one, otherwise what the person picked.
    var interfaceStyle: UIUserInterfaceStyle {
        switch look.appearance {
        case .dark: .dark
        case .light: .light
        case .any: AppAppearance.current.userInterfaceStyle
        }
    }

    /// The tint a window takes: the theme's accent, or under Flaccy's own
    /// theme the picked accent (nothing at all for Blue, as it always was).
    var windowTint: UIColor? {
        isSystemLook ? accent.windowTint : ThemePaint.tint()
    }

    private var windows: [UIWindow] {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
    }

    /// Hands the look to everything that draws with it. Called once before
    /// the first window is shown and again on every change.
    func prepare() {
        epoch += 1
        if isSystemLook {
            ThemePaint.wear(dark: nil, light: nil)
        } else {
            ThemePaint.wear(dark: look.palette(dark: true), light: look.palette(dark: false))
        }
        let faces = ThemeTypography.faces(for: look)
        ThemeTypography.wear(faces)
        ThemeShape.wear(look)
        let shaped = look.corners != ThemePack.cornersStandard || look.covers != .rounded || !look.shadows
        ThemeHooks.wear(dressing: !isSystemLook || !faces.isSystem || shaped, faces: faces, epoch: epoch)
    }

    /// Dresses one window: its mode, its tint and the epoch that makes every
    /// dynamic color resolve again.
    func dress(_ window: UIWindow) {
        window.overrideUserInterfaceStyle = interfaceStyle
        window.tintColor = windowTint
        window.traitOverrides.themeEpoch = epoch
    }

    /// Applies the look to every window, crossfading unless Reduce Motion is on.
    func apply(animated: Bool) {
        prepare()
        for window in windows {
            let change = { self.dress(window) }
            if animated, !UIAccessibility.isReduceMotionEnabled {
                UIView.transition(with: window, duration: 0.3, options: .transitionCrossDissolve, animations: change)
            } else {
                change()
            }
        }
        ThemeHooks.dressEverything(in: windows)
        NotificationCenter.default.post(name: AppTheme.didChange, object: nil)
    }
}
