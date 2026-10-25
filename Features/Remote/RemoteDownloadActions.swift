import FlaccyCore
import UIKit

/// The Download and Remove Download entries of the song, album and playlist menus on iPhone,
/// with the toast that follows a download from its start to its end.
@MainActor
enum RemoteDownloadActions {

    /// The menu entry for these tracks: nil when none is from a server, Remove Download when
    /// every remote one is downloaded already, Download otherwise.
    static func action(for tracks: [Track], in host: UIViewController) -> UIAction? {
        action(forPaths: tracks.compactMap { $0.remoteSong?.path }, in: host)
    }

    static func action(forPaths paths: [String], in host: UIViewController) -> UIAction? {
        guard let state = RemoteDownloads.menuState(for: paths) else { return nil }
        let remote = paths.filter(RemoteTrackPath.isRemote)
        switch state {
        case .download:
            return UIAction(title: RemoteCopy.downloadAction, image: UIImage(systemName: "arrow.down.circle")) { [weak host] _ in
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                guard let host else { return }
                download(paths: remote, in: host.view)
            }
        case .removeDownload:
            return UIAction(title: RemoteCopy.removeDownloadAction, image: UIImage(systemName: "xmark.circle")) { [weak host] _ in
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                Task { @MainActor in
                    let removed = await RemoteDownloads.remove(paths: remote)
                    guard let host else { return }
                    ToastView.show(RemoteCopy.downloadsRemoved(removed), in: host.view, style: .info)
                }
            }
        }
    }

    static func download(paths: [String], in view: UIView) {
        let wanted = paths.filter { !RemoteAvailability.shared.isDownloaded(path: $0) }
        guard !wanted.isEmpty else { return }
        let toast = ToastView.showLive(RemoteCopy.downloading(wanted.count), in: view)
        Task { @MainActor in
            let outcome = await RemoteDownloads.download(paths: wanted) { done, total in
                toast.update(done == 0 ? RemoteCopy.downloading(total) : RemoteCopy.downloading(done: done, of: total))
            }
            if let reason = outcome.failureReason {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                toast.finish(
                    RemoteCopy.downloadFailed(done: outcome.downloaded, total: outcome.total, reason: reason), style: .error
                )
            } else {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                toast.finish(RemoteCopy.downloaded(outcome.downloaded), style: .success)
            }
        }
    }
}
