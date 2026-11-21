import MidgarCore
#if DEBUG
import FlaccyCore
import UIKit

/// Puts every built-in theme on in turn in the running app and proves the
/// look reaches the screen and leaves again without a trace: labels take the
/// theme's face and text color, the window its mode and accent, covers their
/// shape, and Flaccy's own theme afterwards shows every label that was on
/// screen at the start in exactly the font it had. Launch with
/// `--seed-screenshots --exercise-themes` and `FLACCY_ROUTE=library`, then
/// read the app log for `THEME EXERCISE PASSED`. What the person had on is
/// put back at the end.
@MainActor
enum ThemeExercise {

    static let launchArgument = "--exercise-themes"

    private static var failures = 0

    static func runIfRequested() {
        guard CommandLine.arguments.contains(launchArgument) else { return }
        Task { await run() }
    }

    private static func report(_ what: String, _ passed: Bool) {
        if !passed { failures += 1 }
        MidgarLog.info("THEME EXERCISE \(passed ? "ok" : "FAILED"): \(what)", category: .ui)
    }

    private static var window: UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow)
    }

    private static func all<T: UIView>(_ type: T.Type) -> [T] {
        guard let window else { return [] }
        var found: [T] = []
        func walk(_ view: UIView) {
            if let match = view as? T { found.append(match) }
            view.subviews.forEach(walk)
        }
        walk(window)
        return found
    }

    private static func wear(_ pack: String) async {
        AppTheme.shared.edit(animated: false) { $0.wear(pack: pack) }
        try? await Task.sleep(for: .seconds(0.6))
    }

    private static func run() async {
        try? await Task.sleep(for: .seconds(5))
        let theme = AppTheme.shared
        let worn = theme.wardrobe
        await wear(ThemeLibrary.defaultID)
        theme.edit(animated: false) { $0.resetOwnChoices() }
        try? await Task.sleep(for: .seconds(0.4))

        let baseline = all(UILabel.self).map { (label: $0, font: $0.font.fontName, size: $0.font.pointSize) }
        report("labels on screen to judge by (\(baseline.count))", baseline.count > 10)
        report("Flaccy's own theme leaves the window's tint to the accent", window?.tintColor == theme.windowTint || theme.windowTint == nil)

        await wear("phosphor")
        let mono = all(UILabel.self).filter { $0.font.fontName.contains("Mono") }.count
        let labels = all(UILabel.self).count
        report("Phosphor sets labels in the monospaced face (\(mono) of \(labels))", mono * 10 >= labels * 8)
        report("Phosphor holds the window dark", window?.overrideUserInterfaceStyle == .dark)
        let green = UIColor.flaccyLabel.resolvedColor(with: window?.traitCollection ?? .current)
        var (red, greenPart, blue): (CGFloat, CGFloat, CGFloat) = (0, 0, 0)
        green.getRed(&red, green: &greenPart, blue: &blue, alpha: nil)
        report("Phosphor's text is its own green", greenPart > red && greenPart > blue)
        let themedText = all(UILabel.self).filter { $0.textColor == UIColor.flaccyLabel }.count
        report("labels the system colored now wear the theme's text color (\(themedText))", themedText > 0)
        let squared = all(UIImageView.self).compactMap(\.coverShaper).count
        let square = all(UIImageView.self).filter { $0.coverShaper != nil && $0.layer.cornerRadius == 0 }.count
        report("Phosphor squares every cover (\(square) of \(squared))", squared > 0 && square == squared)

        await wear("liner-notes")
        let serif = all(UILabel.self).filter { $0.font.familyName == "Charter" }.count
        report("Liner Notes sets titles in Charter (\(serif))", serif > 0)
        report("Liner Notes holds the window light", window?.overrideUserInterfaceStyle == .light)

        await wear("hi-fi")
        let covers = all(UIImageView.self).filter { $0.coverShaper != nil && $0.bounds.width > 0 }
        let round = covers.filter { abs($0.layer.cornerRadius - min($0.bounds.width, $0.bounds.height) / 2) < 0.6 }.count
        report("Hi-Fi rounds every cover (\(round) of \(covers.count))", !covers.isEmpty && round == covers.count)

        await wear("gallery")
        report("Gallery lays Albums out as a wall", theme.look.albums == .wall)
        await wear("marquee")
        report("Marquee lays Albums out as a carousel", theme.look.albums == .carousel)

        await wear(ThemeLibrary.defaultID)
        let kept = baseline.filter { $0.label.window != nil }
        let restored = kept.filter { $0.label.font.fontName == $0.font && $0.label.font.pointSize == $0.size }.count
        report("back on Flaccy's own theme every label has the font it had (\(restored) of \(kept.count))", restored == kept.count && !kept.isEmpty)
        report("the window's mode is the person's again", window?.overrideUserInterfaceStyle == AppAppearance.current.userInterfaceStyle)
        let plain = UIColor.flaccyLabel.resolvedColor(with: window?.traitCollection ?? .current)
        report("text is the system's again", plain == UIColor.label.resolvedColor(with: window?.traitCollection ?? .current))

        theme.edit(animated: false) { $0 = worn }
        MidgarLog.info(failures == 0 ? "THEME EXERCISE PASSED" : "THEME EXERCISE FAILED (\(failures))", category: .ui)
    }
}
#endif
