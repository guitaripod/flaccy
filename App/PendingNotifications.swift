import UserNotifications

/// Withdraws scheduled notifications without holding the main actor. The
/// removal is a synchronous round trip to the notification daemon, which can
/// take seconds while that daemon is busy (it held a fresh install's main
/// thread for eight), and both schedulers run it on every activation.
enum PendingNotifications {

    @concurrent
    nonisolated static func remove(withIdentifiers identifiers: [String]) async {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
    }
}
