import AppKit
import MidgarCore

/// Everything the Mac does at an activation edge for the trial's last stretch,
/// in one place and in one order: the day re-derived first, then the one-time
/// day-6 toast (the titlebar pill re-reads the state on its own), then the
/// pending reminders rebuilt for today. Nothing here is modal and nothing here
/// presents the paywall or the reminder consent — App Review rejects an
/// auto-popped sheet or alert on foreground; consent is offered only at a
/// completed play through `TrialReminderScheduler.optInOpportunity`, and the
/// pill is one click away.
@MainActor
enum MacTrialRunwayPresenter {

    private static var secondLookObserver: NSObjectProtocol?

    static func refresh(in window: NSWindow?) {
        MacTrialReminderPrompt.observeOpportunities()
        observeSecondLook()
        PurchaseManager.shared.refreshTrialPhase()
        showRunwayToastIfDue(in: window)
        Task { await TrialReminderScheduler.shared.refresh() }
    }

    /// A second look starts at a play, with nothing on screen changing but the
    /// card that offered it leaving, so the moment is said once in a toast.
    private static func observeSecondLook() {
        guard secondLookObserver == nil else { return }
        secondLookObserver = NotificationCenter.default.addObserver(
            forName: PurchaseManager.secondLookDidStart, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                guard let window = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain })
                else { return }
                MacToast.show(PaywallCopy.secondLookStartedToast, style: .success, in: window)
            }
        }
    }

    private static func showRunwayToastIfDue(in window: NSWindow?) {
        let manager = PurchaseManager.shared
        guard manager.runwayBannerIsDue, let window, window.isVisible else { return }
        manager.markRunwayPromptShown()
        MacToast.show(
            PaywallCopy.runwayToast,
            style: .info, in: window
        )
        MidgarLog.info("Trial runway toast shown", category: .purchases)
    }
}
