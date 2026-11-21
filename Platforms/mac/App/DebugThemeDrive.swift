import MidgarCore
#if DEBUG
import AppKit
import FlaccyCore

/// Theme captures and the theme exercise for development builds.
/// `--hide-onboarding` keeps the welcome panel off a capture taken in a
/// throwaway home, which has no music folder. `--exercise-themes` puts every
/// built-in theme on the running app and off again and logs PASS or FAIL for
/// what each should have changed. Compiled out of Release.
enum DebugThemeDrive {

    static func prepareIfRequested() {
        if CommandLine.arguments.contains("--hide-onboarding") {
            OnboardingPanelView.isSuppressedForCapture = true
        }
    }

    static func runIfRequested(window: NSWindow?) {
        guard CommandLine.arguments.contains("--exercise-themes") else { return }
        Task { await exercise(window: window) }
    }

    private struct Census {
        var labels = 0
        var monospaced = 0
        var themedInk = 0
        var covers = 0
        var squareCovers = 0
        var roundCovers = 0
        var fonts: [ObjectIdentifier: String] = [:]
        var monospacedLabels: Set<ObjectIdentifier> = []

        /// The labels that were set in the system's own font, which is what
        /// a theme's face replaces.
        var systemLabels: Set<ObjectIdentifier> {
            Set(fonts.filter { $0.value.hasPrefix(".") }.keys)
        }
    }

    private static var failures = 0

    private static func isMonospaced(_ font: NSFont) -> Bool {
        font.fontDescriptor.symbolicTraits.contains(.monoSpace) || font.fontName.contains("Mono")
    }

    /// Counts what the look has done to every label, button and cover in
    /// `window`. The label a button keeps inside itself is the button's own
    /// business and is counted with the button.
    private static func census(of window: NSWindow?) -> Census {
        var census = Census()
        let ink = NSColor.flaccyLabel
        func walk(_ view: NSView) {
            let isButtonsOwnLabel = view.superview is NSButton
            if let control = view as? NSControl, control is NSTextField || control is NSButton, !isButtonsOwnLabel,
               !control.isHidden, let font = control.font {
                census.labels += 1
                census.fonts[ObjectIdentifier(control)] = font.fontName
                if isMonospaced(font) {
                    census.monospaced += 1
                    census.monospacedLabels.insert(ObjectIdentifier(control))
                }
                if (control as? NSTextField)?.textColor === ink { census.themedInk += 1 }
            }
            if let shaper = view.macCoverShaper, !view.bounds.isEmpty {
                census.covers += 1
                let side = min(view.bounds.width, view.bounds.height)
                if shaper.shownRadius == 0 { census.squareCovers += 1 }
                if abs(shaper.shownRadius - side / 2) < 0.5 { census.roundCovers += 1 }
            }
            view.subviews.forEach(walk)
        }
        if let root = window?.contentView?.superview ?? window?.contentView { walk(root) }
        return census
    }

    /// Names the labels a check did not find as it expected, so a failure
    /// says which.
    private static func logLabels(in window: NSWindow?, among ids: Set<ObjectIdentifier>) {
        func walk(_ view: NSView) {
            if let control = view as? NSControl, ids.contains(ObjectIdentifier(control)) {
                MidgarLog.info(
                    "ThemeExercise label \(type(of: control)) in \(type(of: control.superview)) \"\(control.stringValue.prefix(24))\" \(control.font?.fontName ?? "-")",
                    category: .general
                )
            }
            view.subviews.forEach(walk)
        }
        if let root = window?.contentView?.superview ?? window?.contentView { walk(root) }
    }

    private static func report(_ expectation: String, _ passed: Bool, _ detail: String) {
        if !passed { failures += 1 }
        MidgarLog.info("ThemeExercise \(passed ? "PASS" : "FAIL"): \(expectation) (\(detail))", category: .general)
    }

    private static func settle() async {
        try? await Task.sleep(for: .milliseconds(700))
    }

    private static func exercise(window: NSWindow?) async {
        var attempts = 0
        while Library.shared.albums.isEmpty, attempts < 40 {
            try? await Task.sleep(for: .milliseconds(500))
            attempts += 1
        }
        NotificationCenter.default.post(
            name: .flaccyShowSection, object: nil,
            userInfo: [SectionNotificationKey.section: SidebarSection.albums.rawValue]
        )
        try? await Task.sleep(for: .seconds(2))
        let theme = MacTheme.shared
        theme.edit { $0 = ThemeWardrobe() }
        await settle()
        let before = census(of: window)
        report("the app starts in Flaccy's own look with its own fonts", before.monospaced < before.labels / 4, "\(before.monospaced) of \(before.labels) monospaced")
        report("covers start rounded", before.covers > 0 && before.squareCovers == 0 && before.roundCovers == 0, "\(before.covers) covers")

        theme.edit { $0.wear(pack: "phosphor") }
        await settle()
        let phosphor = census(of: window)
        let kept = before.systemLabels.intersection(phosphor.fonts.keys)
        let faced = kept.intersection(phosphor.monospacedLabels)
        report("Phosphor sets every label and button that had the system's font in its monospaced face", !kept.isEmpty && faced.count == kept.count, "\(faced.count) of \(kept.count), \(phosphor.monospaced) of all \(phosphor.labels)")
        logLabels(in: window, among: kept.subtracting(faced))
        report("Phosphor inks labels in its own text color", phosphor.themedInk > phosphor.labels / 4, "\(phosphor.themedInk) of \(phosphor.labels)")
        report("Phosphor draws every cover square", phosphor.covers > 0 && phosphor.squareCovers == phosphor.covers, "\(phosphor.squareCovers) of \(phosphor.covers)")
        report("Phosphor holds the app dark and shows Albums as a list", NSApp.appearance?.name == .darkAqua && theme.look.albums == .list, theme.look.albums.id)

        theme.edit { $0.wear(pack: "liner-notes") }
        await settle()
        report("Liner Notes holds the app light", NSApp.appearance?.name == .aqua, NSApp.appearance?.name.rawValue ?? "nil")

        theme.edit { $0.wear(pack: "hi-fi") }
        await settle()
        let hifi = census(of: window)
        report("Hi-Fi draws every cover round", hifi.covers > 0 && hifi.roundCovers == hifi.covers, "\(hifi.roundCovers) of \(hifi.covers)")

        theme.edit { $0.wear(pack: "gallery") }
        await settle()
        report("Gallery shows Albums as a wall", theme.look.albums == .wall, theme.look.albums.id)
        theme.edit { $0.show(albumsAs: "carousel") }
        await settle()
        report("a view switched under a theme is remembered with it", theme.wardrobe.remembered("gallery").view == "carousel", theme.wardrobe.remembered("gallery").view)

        theme.edit { $0 = ThemeWardrobe() }
        await settle()
        let after = census(of: window)
        let restored = after.fonts.filter { before.fonts[$0.key] == $0.value }.count
        let comparable = after.fonts.keys.filter { before.fonts[$0] != nil }.count
        report("back in Flaccy's own look every label has the font it started with", comparable > 0 && restored == comparable, "\(restored) of \(comparable)")
        report("and no label keeps a theme's ink", after.themedInk == 0 || !ThemePalettes.isPainting, "\(after.themedInk) wrappers, painting \(ThemePalettes.isPainting)")
        report("the system decides light and dark again", NSApp.appearance == nil, NSApp.appearance?.name.rawValue ?? "nil")
        MidgarLog.info("THEME EXERCISE \(failures == 0 ? "PASSED" : "FAILED (\(failures))")", category: .general)
    }
}
#endif
