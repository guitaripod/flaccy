import AppKit

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

    static func refresh(in window: NSWindow?) {
        MacTrialReminderPrompt.observeOpportunities()
        PurchaseManager.shared.refreshTrialPhase()
        showRunwayToastIfDue(in: window)
        Task { await TrialReminderScheduler.shared.refresh() }
    }

    private static func showRunwayToastIfDue(in window: NSWindow?) {
        let manager = PurchaseManager.shared
        guard manager.runwayBannerIsDue, let window, window.isVisible else { return }
        manager.markRunwayPromptShown()
        MacToast.show(
            PaywallCopy.runwayToast,
            style: .info, in: window
        )
        AppLogger.info("Trial runway toast shown", category: .purchases)
    }
}
