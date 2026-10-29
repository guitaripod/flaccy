import AVFoundation
import MidgarCore
import UIKit
import UserNotifications

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        FlaccyMidgar.configureLogging()
        FlaccyMidgar.shared.start()
        ReviewPrompt.beginSession()
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        } catch {
            MidgarLog.error("Audio session category failed: \(error.localizedDescription)", category: .playback)
        }

        UNUserNotificationCenter.current().delegate = self
        EqualizerEngine.shared.start()
        WatchSyncService.shared.activate()
        PurchaseManager.shared.start()
        ServerSyncBackgroundRefresh.register()
        ServerSyncLifecycle.shared.launched()

        Task {
            await AudioPlayer.shared.retryPendingScrobbles()
            ListenHistorySync.shared.start()
        }

        return true
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        switch (
            userInfo[RecapNotificationScheduler.destinationUserInfoKey] as? String,
            userInfo[TrialReminderScheduler.destinationUserInfoKey] as? String
        ) {
        case (RecapNotificationScheduler.yearInMusicDestination?, _):
            presentYearInMusic()
        case (_, TrialReminderScheduler.paywallDestination?):
            MidgarLog.info("Trial reminder tapped: \(response.notification.request.identifier)", category: .purchases)
            PurchaseManager.shared.requestPaywall()
        default:
            break
        }
    }

    private func presentYearInMusic() {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }
        guard let root = scene?.keyWindow?.rootViewController else { return }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        guard !(top is YearInMusicViewController) else { return }
        top.present(YearInMusicViewController(), animated: true)
    }
}
