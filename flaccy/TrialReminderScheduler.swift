import Foundation
import UserNotifications

/// The three opt-in reminders around the end of the trial — two days before,
/// the last day, and once if a welcome-back price on Lifetime opens up — built
/// from `TrialRunway` so a tapped notification, the paywall and the banner all
/// agree on which day it is. Consent lives in UserDefaults on purpose: a
/// reinstall also resets notification authorization, so asking again is right.
final class TrialReminderScheduler {

    static let shared = TrialReminderScheduler()

    static let destinationUserInfoKey = "trial.destination"
    static let paywallDestination = "paywall"
    static let optInOpportunity = Notification.Name("TrialReminderOptInOpportunity")
    static let enabledKey = "flaccy.trialReminders.enabled"
    static let askedKey = "flaccy.trialReminders.asked"

    private static let identifiers = TrialRunway.Reminder.Kind.allCases.map(\.rawValue)

    private let center = UNUserNotificationCenter.current()

    private init() {}

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    var hasBeenAsked: Bool {
        UserDefaults.standard.bool(forKey: Self.askedKey)
    }

    func markAsked() {
        UserDefaults.standard.set(true, forKey: Self.askedKey)
    }

    /// Requests alert and sound authorization; on a grant the reminders are
    /// scheduled at once, on a denial the toggle stays off so Settings can say so.
    func enable() async -> Bool {
        let granted: Bool
        do {
            granted = try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            AppLogger.error("Trial reminder authorization failed: \(error.localizedDescription)", category: .purchases)
            granted = false
        }
        UserDefaults.standard.set(granted, forKey: Self.enabledKey)
        guard granted else {
            AppLogger.warning("Trial reminders requested but notifications are denied", category: .purchases)
            return false
        }
        AppLogger.info("Trial reminders enabled", category: .purchases)
        await refresh()
        return true
    }

    func disable() {
        cancelAll()
        UserDefaults.standard.set(false, forKey: Self.enabledKey)
        AppLogger.info("Trial reminders disabled", category: .purchases)
    }

    /// Rebuilds the pending reminders from the current trial phase: all three
    /// while the trial runs, only the welcome-back one once it has expired, and
    /// none at all after a purchase or when reminders are off.
    func refresh() async {
        guard isEnabled else {
            cancelAll()
            return
        }
        let manager = PurchaseManager.shared
        guard !manager.state.isPurchased else {
            cancelAll()
            return
        }
        guard !manager.trialClockIsOverridden else {
            AppLogger.info("Trial reminder scheduling skipped under --trial-day", category: .purchases)
            return
        }
        let start = manager.trialStart
        let reminders = TrialRunway.reminders(
            start: start,
            now: Date(),
            calendar: .current,
            includeWelcomeBack: manager.lapsedOfferingExists
        )
        let wanted = manager.state == .expired ? reminders.filter { $0.kind == .welcomeBack } : reminders
        await replacePending(with: wanted, welcomeBackEnds: TrialRunway.lapsedOfferEnd(start: start))
    }

    func cancelAll() {
        center.removePendingNotificationRequests(withIdentifiers: Self.identifiers)
    }

    func hasPendingRequests() async -> Bool {
        let pending = await center.pendingNotificationRequests()
        return pending.contains { Self.identifiers.contains($0.identifier) }
    }

    /// One request per reminder, identified by its kind, carrying no price and
    /// routing every tap to the paywall. The fire time is matched as calendar
    /// components so a device asleep at that minute still delivers it next.
    static func requests(for reminders: [TrialRunway.Reminder], welcomeBackEnds: Date) -> [UNNotificationRequest] {
        reminders.map { reminder in
            let content = UNMutableNotificationContent()
            content.title = title(for: reminder.kind)
            content.body = body(for: reminder.kind, welcomeBackEnds: welcomeBackEnds)
            content.sound = .default
            content.userInfo = [destinationUserInfoKey: paywallDestination]
            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second], from: reminder.fireAt
            )
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            return UNNotificationRequest(identifier: reminder.kind.rawValue, content: content, trigger: trigger)
        }
    }

    private static func title(for kind: TrialRunway.Reminder.Kind) -> String {
        switch kind {
        case .twoDaysLeft: String(localized: "2 days left in your Flaccy trial")
        case .ended: String(localized: "Your Flaccy trial has ended")
        case .welcomeBack: String(localized: "Welcome back to Flaccy")
        }
    }

    private static func body(for kind: TrialRunway.Reminder.Kind, welcomeBackEnds: Date) -> String {
        switch kind {
        case .twoDaysLeft:
            String(localized: "Open Flaccy to keep everything you've set up.")
        case .ended:
            String(localized: "Everything you set up is still here.")
        case .welcomeBack:
            String(localized: "A welcome-back price on Lifetime is available until \(welcomeBackEnds.formatted(.dateTime.day().month())).")
        }
    }

    private func replacePending(with reminders: [TrialRunway.Reminder], welcomeBackEnds: Date) async {
        cancelAll()
        for request in Self.requests(for: reminders, welcomeBackEnds: welcomeBackEnds) {
            do {
                try await center.add(request)
                AppLogger.info("Scheduled \(request.identifier) trial reminder", category: .purchases)
            } catch {
                AppLogger.error("Scheduling \(request.identifier) failed: \(error.localizedDescription)", category: .purchases)
            }
        }
    }
}
