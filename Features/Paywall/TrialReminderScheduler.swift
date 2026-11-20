import Foundation
import MidgarCore
import UserNotifications

/// The opt-in reminders around the end of the trial — two days before, the
/// last day, once if a welcome-back price on Lifetime opens up, and once a
/// month later when a second look does — built from `TrialRunway` so a tapped
/// notification, the paywall and the banner all agree on which day it is.
/// Consent lives in UserDefaults on purpose: a reinstall also resets
/// notification authorization, so asking again is right. The second look's
/// reminder goes only to someone who agreed under the wording that names it.
final class TrialReminderScheduler {

    static let shared = TrialReminderScheduler()

    static let destinationUserInfoKey = "trial.destination"
    static let paywallDestination = "paywall"
    static let optInOpportunity = Notification.Name("TrialReminderOptInOpportunity")
    static let enabledKey = "flaccy.trialReminders.enabled"
    static let askedKey = "flaccy.trialReminders.asked"
    static let coversSecondLookKey = "flaccy.trialReminders.coversSecondLook"

    private static let identifiers = TrialRunway.Reminder.Kind.allCases.map(\.rawValue)

    private let center = UNUserNotificationCenter.current()

    private init() {}

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    var hasBeenAsked: Bool {
        UserDefaults.standard.bool(forKey: Self.askedKey)
    }

    /// Whether the reminders were switched on under the wording that counts
    /// four notifications. Someone who agreed to three is never sent a fourth.
    var consentCoversSecondLook: Bool {
        UserDefaults.standard.bool(forKey: Self.coversSecondLookKey)
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
            MidgarLog.error("Trial reminder authorization failed: \(error.localizedDescription)", category: .purchases)
            granted = false
        }
        UserDefaults.standard.set(granted, forKey: Self.enabledKey)
        guard granted else {
            MidgarLog.notice("Trial reminders requested but notifications are denied", category: .purchases)
            return false
        }
        UserDefaults.standard.set(true, forKey: Self.coversSecondLookKey)
        MidgarLog.info("Trial reminders enabled", category: .purchases)
        await refresh()
        return true
    }

    func disable() {
        Task { await cancelAll() }
        UserDefaults.standard.set(false, forKey: Self.enabledKey)
        MidgarLog.info("Trial reminders disabled", category: .purchases)
    }

    /// Rebuilds the pending reminders from the current trial phase: all of them
    /// while the trial runs, the welcome-back and second-look ones once it has
    /// expired, and none at all before the trial starts, after a purchase, when
    /// reminders are off, or once a second look is waiting or has begun (it
    /// sends none of its own).
    func refresh() async {
        guard isEnabled else {
            await cancelAll()
            return
        }
        let manager = PurchaseManager.shared
        guard !manager.state.isPurchased else {
            await cancelAll()
            return
        }
        guard manager.state != .trialNotStarted else {
            await cancelAll()
            return
        }
        guard !manager.trialClockIsOverridden else {
            MidgarLog.info("Trial reminder scheduling skipped under --trial-day", category: .purchases)
            return
        }
        guard manager.state != .secondLookReady, !manager.isSecondLook else {
            await cancelAll()
            return
        }
        let start = manager.trialStart
        let reminders = TrialRunway.reminders(
            start: start,
            now: Date(),
            calendar: .current,
            includeWelcomeBack: manager.lapsedOfferExists,
            includeSecondLook: consentCoversSecondLook
        )
        let wanted = manager.state == .expired ? reminders.filter(\.kind.firesAfterTheTrial) : reminders
        await replacePending(with: wanted, welcomeBackEnds: TrialRunway.lapsedOfferEnd(start: start))
    }

    func cancelAll() async {
        await PendingNotifications.remove(withIdentifiers: Self.identifiers)
    }

    func hasPendingRequests() async -> Bool {
        let pending = await center.pendingNotificationRequests()
        return pending.contains { Self.identifiers.contains($0.identifier) }
    }

    /// One request per reminder, identified by its kind and carrying no price.
    /// A tap opens the paywall, except on the second look's, which has free
    /// days to give and so only opens the app. The fire time is matched as
    /// calendar components so a device asleep at that minute still delivers it
    /// next.
    static func requests(for reminders: [TrialRunway.Reminder], welcomeBackEnds: Date) -> [UNNotificationRequest] {
        reminders.map { reminder in
            let content = UNMutableNotificationContent()
            content.title = title(for: reminder.kind)
            content.body = body(for: reminder.kind, welcomeBackEnds: welcomeBackEnds)
            content.sound = .default
            if reminder.kind != .secondLook {
                content.userInfo = [destinationUserInfoKey: paywallDestination]
            }
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
        case .secondLook: PaywallCopy.secondLookTitle
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
        case .secondLook:
            PaywallCopy.secondLookLine
        }
    }

    private func replacePending(with reminders: [TrialRunway.Reminder], welcomeBackEnds: Date) async {
        await cancelAll()
        for request in Self.requests(for: reminders, welcomeBackEnds: welcomeBackEnds) {
            do {
                try await center.add(request)
                MidgarLog.info("Scheduled \(request.identifier) trial reminder", category: .purchases)
            } catch {
                MidgarLog.error("Scheduling \(request.identifier) failed: \(error.localizedDescription)", category: .purchases)
            }
        }
    }
}

extension TrialRunway.Reminder.Kind {

    /// The reminders that still lie ahead once the trial has run out.
    var firesAfterTheTrial: Bool {
        switch self {
        case .welcomeBack, .secondLook: true
        case .twoDaysLeft, .ended: false
        }
    }
}
