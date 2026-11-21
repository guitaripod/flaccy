import UIKit

/// Opens the 2.0 showcase over the app on the launch that should have it, then hands the launch on to whatever
/// comes next.
@MainActor
enum ShowcaseFlow {

    /// How long the app is on screen before the showcase rises over it, so it arrives over something and not out
    /// of the launch itself.
    private static let pause: Duration = .milliseconds(450)

    /// The size of the card the showcase is where there is room for one, as on an iPad; an iPhone gives it the
    /// whole sheet.
    private static let cardSize = CGSize(width: 540, height: 720)

    /// Shows the showcase when this launch should have it and calls `next` when it has closed, or at once when there
    /// is none to show. `next` hears whether a showcase was shown.
    static func presentIfNeeded(over host: UIViewController, then next: @escaping (_ followedShowcase: Bool) -> Void) {
        let forced = ShowcaseGate.isForced()
        guard ShowcaseGate.shouldPresent(
            seenEdition: ShowcaseGate.seenEdition, isAutomated: ShowcaseGate.isAutomatedRun(), forced: forced
        ) else {
            next(false)
            return
        }
        if !forced { ShowcaseGate.markSeen() }
        Task { @MainActor in
            try? await Task.sleep(for: pause)
            guard host.presentedViewController == nil, host.view.window != nil else {
                next(false)
                return
            }
            present(over: host, opensOnEverything: forced && ShowcaseGate.opensOnEverything(), then: next)
        }
    }

    private static func present(over host: UIViewController, opensOnEverything: Bool, then next: @escaping (Bool) -> Void) {
        let showcase = ShowcaseViewController()
        let navigation = UINavigationController(rootViewController: showcase)
        navigation.modalPresentationStyle = .formSheet
        navigation.preferredContentSize = cardSize
        navigation.isModalInPresentation = true
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = false
            sheet.preferredCornerRadius = 28
        }
        showcase.onFinish = {
            navigation.dismiss(animated: true) { next(true) }
        }
        host.present(navigation, animated: true)
        if opensOnEverything { showcase.showEverything(animated: false) }
    }
}
