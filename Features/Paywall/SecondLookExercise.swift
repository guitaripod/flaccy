import MidgarCore
#if DEBUG
import FlaccyCore
import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Walks a waiting second look on a real device: launch with
/// `--trial-day 38 --exercise-second-look` on one that holds music of its own.
/// It checks that the look waits with playback open and Home showing its
/// card, presses the card's Play My Music, and checks that seven free days and
/// the welcome-back window began with that play. `SecondLookExercise PASS/FAIL`
/// lines go to the app log and two pictures to `Library/Caches` on the iPhone
/// and iPad, kept out of the music in Documents, and to the capture folder on
/// the Mac. Under
/// `--trial-day` nothing reaches the Keychain, the signals or the pending
/// reminders, so the device's own trial is exactly as it was afterwards.
@MainActor
enum SecondLookExercise {

    static let launchArgument = "--exercise-second-look"

    private static var failures = 0

    static func runIfRequested() {
        guard CommandLine.arguments.contains(launchArgument) else { return }
        Task { await run() }
    }

    private static func run() async {
        let manager = PurchaseManager.shared
        guard await settles(within: 20, { manager.hasLoadedEntitlements }) else {
            return finish(reason: "the entitlements never loaded")
        }
        guard manager.state == .secondLookReady else {
            return finish(reason: "expected a waiting second look, found \(manager.state); launch with --trial-day 38 on an install that has not bought Flaccy")
        }
        check("playback is open while the second look waits", manager.allowsPlayback)
        check("no welcome-back price before it starts", manager.lapsedOfferState == .notYet)
        check("Home shows the second look's card", await settles(within: 20) { homeShowsTheCard })
        await pause(5)
        capture("second-look-card")

        pressPlayMyMusic()
        check("the play starts the second look", await settles(within: 15) { manager.isSecondLook })
        check("seven free days are counting", manager.state == .trial(daysRemaining: TrialRunway.lengthDays))
        check("the welcome-back window is open through the second look", welcomeBackWindowIsOpen)
        MidgarLog.info(
            "SecondLookExercise: welcome-back product on offer: \(manager.lifetimeOfferToPresent?.isWelcomeBack == true)",
            category: .purchases
        )
        await pause(4)
        capture("second-look-started")
        if AudioPlayer.shared.isPlaying { AudioPlayer.shared.togglePlayPause() }
        finish(reason: nil)
    }

    private static var welcomeBackWindowIsOpen: Bool {
        guard case .available(let endsAt) = PurchaseManager.shared.lapsedOfferState else { return false }
        let expected = Date().addingTimeInterval(TimeInterval(TrialRunway.lengthDays + TrialRunway.lapsedOfferDelayDays + TrialRunway.lapsedOfferWindowDays) * TrialRunway.day)
        return abs(endsAt.timeIntervalSince(expected)) < 120
    }

    private static func check(_ what: String, _ passed: Bool) {
        if !passed { failures += 1 }
        MidgarLog.info("SecondLookExercise \(passed ? "PASS" : "FAIL"): \(what)", category: .purchases)
    }

    private static func finish(reason: String?) {
        if let reason {
            MidgarLog.error("SecondLookExercise FAIL: \(reason)", category: .purchases)
            return
        }
        MidgarLog.info(
            failures == 0 ? "SecondLookExercise PASS: all checks" : "SecondLookExercise FAIL: \(failures) checks failed",
            category: .purchases
        )
    }

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// Polls a condition the main actor settles in its own time: a store
    /// answer, a feed built off the main thread, a track that has begun.
    private static func settles(within seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            await pause(0.25)
        }
        return condition()
    }

    #if os(macOS)
    private static var window: NSWindow? {
        NSApp.mainWindow ?? NSApp.windows.first(where: \.isVisible)
    }

    /// The Mac's card is checked in the picture: the page builds its views
    /// from the same `HomePromoContent`, with no model to ask.
    private static var homeShowsTheCard: Bool {
        HomePromo.Phase(PurchaseManager.shared.state) == .secondLookReady
    }

    private static func pressPlayMyMusic() {
        MacHomeActions.shuffleLibrary()
    }

    private static func capture(_ name: String) {
        DebugDrive.capture(window: window, name: "flaccy-" + name)
    }
    #else
    private static var window: UIWindow? {
        TrialRunwayPresenter.activeWindow
    }

    private static var homeShowsTheCard: Bool {
        guard case .secondLook = TrialRunwayPresenter.home(in: window)?.promoContent else { return false }
        return true
    }

    private static func pressPlayMyMusic() {
        TrialRunwayPresenter.home(in: window)?.handle(promo: .playMyMusic)
    }

    private static func capture(_ name: String) {
        guard let window else { return }
        PaywallShot.capture(window, as: name + ".png", in: .cachesDirectory)
    }
    #endif
}
#endif
