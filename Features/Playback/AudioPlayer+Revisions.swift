import FlaccyCore
import MidgarCore
import Foundation

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

extension AudioPlayer {

    /// A re-exported file keeps its name but not its bytes, and the item the
    /// player holds keeps reading the file it opened. When the playing song has
    /// a new version, offers to start it again from the new file.
    @objc func handleTracksRevised(_ notification: Notification) {
        guard let track = currentTrack,
              let paths = notification.userInfo?[Library.RevisionKey.paths] as? [String],
              paths.contains(LibraryPaths.relativePath(of: track.fileURL))
        else { return }
        let index = currentIndex
        MidgarLog.info("The playing track has a new mix: \(track.title)", category: .playback)
        offerNewMix(of: track) { [weak self] in
            guard let self, self.currentIndex == index, self.currentTrack?.fileURL == track.fileURL else { return }
            self.jumpToIndex(index)
        }
    }

    private func offerNewMix(of track: Track, playFromStart: @escaping @MainActor () -> Void) {
        let message = String(localized: "New mix of \u{201C}\(track.title)\u{201D}")
        let actionTitle = String(localized: "Play from start")
        #if canImport(UIKit)
        guard let host = Self.toastHost else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        ToastView.showAction(message, actionTitle: actionTitle, in: host, style: .info) {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            playFromStart()
        }
        #else
        MacToast.showAction(message, actionTitle: actionTitle, style: .info, in: NSApp.keyWindow ?? NSApp.mainWindow) {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            playFromStart()
        }
        #endif
    }

    #if canImport(UIKit)
    private static var toastHost: UIView? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .keyWindow?.rootViewController?.view
    }
    #endif
}
