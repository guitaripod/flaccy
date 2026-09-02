import UIKit

/// The consent alert behind the trial reminders. It is offered at a completed
/// play in the window where both trial reminders still lie ahead, only while
/// nothing else is on screen, and it is stamped as asked only when the person
/// actually saw it — a missed window is never asked for later.
@MainActor
enum TrialReminderPrompt {

    private static var opportunityObserver: NSObjectProtocol?

    static func observeOpportunities() {
        guard opportunityObserver == nil else { return }
        opportunityObserver = NotificationCenter.default.addObserver(
            forName: TrialReminderScheduler.optInOpportunity, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { offerIfDue() }
        }
    }

    static func offerIfDue() {
        guard PurchaseManager.shared.reminderOptInIsDue,
              UIApplication.shared.applicationState == .active,
              let window = TrialRunwayPresenter.activeWindow,
              let top = TrialRunwayPresenter.topmostViewController(in: window),
              top.presentedViewController == nil,
              !(top is PaywallViewController),
              !(top is UIAlertController),
              TrialRunwayPresenter.library(in: window)?.isShowingDebut != true
        else { return }
        present(from: top)
    }

    private static func present(from presenter: UIViewController) {
        let alert = UIAlertController(
            title: PaywallCopy.reminderConsentTitle,
            message: PaywallCopy.reminderConsentBody,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: PaywallCopy.noThanks, style: .cancel) { _ in
            AppLogger.info("Trial reminders declined", category: .purchases)
        })
        let remind = UIAlertAction(title: PaywallCopy.remindMe, style: .default) { [weak presenter] _ in
            Task { await enableReminders(from: presenter) }
        }
        alert.addAction(remind)
        alert.preferredAction = remind
        TrialReminderScheduler.shared.markAsked()
        presenter.present(alert, animated: true)
        AppLogger.info("Trial reminder consent asked", category: .purchases)
    }

    private static func enableReminders(from presenter: UIViewController?) async {
        guard await TrialReminderScheduler.shared.enable() else {
            guard let presenter, let window = presenter.view.window,
                  let top = TrialRunwayPresenter.topmostViewController(in: window)
            else { return }
            showNotificationsDenied(from: top)
            return
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// A refused system permission leaves the reminders off, so the one useful
    /// thing to offer is the way to Flaccy's notification settings.
    static func showNotificationsDenied(from presenter: UIViewController) {
        let alert = UIAlertController(
            title: String(localized: "Notifications Are Off"),
            message: PaywallCopy.notificationsOffHint,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "Not Now"), style: .cancel))
        let open = UIAlertAction(title: String(localized: "Open Settings"), style: .default) { _ in
            guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
            UIApplication.shared.open(url)
        }
        alert.addAction(open)
        alert.preferredAction = open
        presenter.present(alert, animated: true)
    }
}
