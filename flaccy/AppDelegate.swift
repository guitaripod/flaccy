import AVFoundation
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        } catch {
            AppLogger.error("Audio session category failed: \(error.localizedDescription)", category: .playback)
        }

        WatchSyncService.shared.activate()

        Task {
            await AudioPlayer.shared.retryPendingScrobbles()
        }

        return true
    }
}
