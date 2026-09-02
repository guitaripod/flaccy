import AppKit
import Combine

/// The one consent alert behind the trial reminders, asked as a sheet on the
/// main window at a completed play between day two and day five — never over
/// the Debut, another sheet or a presented controller, and never while the app
/// is in the background. `asked` is stamped only when the sheet actually shows,
/// so a missed moment simply waits for the next play.
@MainActor
enum MacTrialReminderPrompt {

    private static var observer: NSObjectProtocol?

    /// Listens for the completed-play opportunity the audio player posts.
    /// Idempotent; the first runway refresh installs it.
    static func observeOpportunities() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: TrialReminderScheduler.optInOpportunity, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { offerIfDue() }
        }
    }

    /// The completed-play path has no window in hand, so it resolves the main
    /// window once and hands it on; activation edges pass theirs directly.
    static func offerIfDue() {
        offerIfDue(in: mainWindow)
    }

    static func offerIfDue(in window: NSWindow?) {
        guard PurchaseManager.shared.reminderOptInIsDue,
              NSApp.isActive,
              MacLibrarySurfaceModel.shared.state.value.surface != .debut,
              let window, window.isVisible,
              window.sheets.isEmpty,
              window.contentViewController?.presentedViewControllers?.isEmpty ?? true
        else { return }
        TrialReminderScheduler.shared.markAsked()
        AppLogger.info("Trial reminder consent asked", category: .purchases)

        let alert = NSAlert()
        alert.messageText = PaywallCopy.reminderConsentTitle
        alert.informativeText = PaywallCopy.reminderConsentBody
        alert.addButton(withTitle: PaywallCopy.remindMe)
        alert.addButton(withTitle: PaywallCopy.noThanks)
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else {
                AppLogger.info("Trial reminders declined", category: .purchases)
                return
            }
            Task { await enableOrExplain(in: window) }
        }
    }

    /// Runs the system authorization request and, when it is refused, points
    /// the reader at the one switch that can change the answer.
    static func enableOrExplain(in window: NSWindow?) async {
        guard await TrialReminderScheduler.shared.enable() == false else { return }
        MacToast.show(PaywallCopy.notificationsOffHint, style: .info, in: window)
        MacSystemSettings.openNotifications()
    }

    private static var mainWindow: NSWindow? {
        if let main = NSApp.mainWindow, main.contentViewController is RootContainerViewController {
            return main
        }
        return NSApp.windows.first { $0.contentViewController is RootContainerViewController }
    }
}
