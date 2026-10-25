import AppKit
import FlaccyCore

/// The Download and Remove Download entries of the song, album and playlist menus on the Mac,
/// with the toast that follows a download from its start to its end.
@MainActor
enum MacRemoteDownloadActions {

    /// The menu item for these tracks: nil when none is from a server, Remove Download when
    /// every remote one is downloaded already, Download otherwise.
    static func menuItem(for tracks: [Track], window: NSWindow?) -> NSMenuItem? {
        guard let state = RemoteDownloads.menuState(for: tracks) else { return nil }
        let remote = tracks.compactMap { $0.remoteSong?.path }
        switch state {
        case .download:
            return ClosureMenuItem(title: RemoteCopy.downloadAction, systemImage: "arrow.down.circle") {
                download(paths: remote, in: window)
            }
        case .removeDownload:
            return ClosureMenuItem(title: RemoteCopy.removeDownloadAction, systemImage: "xmark.circle") {
                Task { @MainActor in
                    let removed = await RemoteDownloads.remove(paths: remote)
                    MacToast.show(RemoteCopy.downloadsRemoved(removed), style: .info, in: window)
                }
            }
        }
    }

    static func download(paths: [String], in window: NSWindow?) {
        let wanted = paths.filter { !RemoteAvailability.shared.isDownloaded(path: $0) }
        guard !wanted.isEmpty else { return }
        let toast = MacToast.showLive(RemoteCopy.downloading(wanted.count), in: window)
        Task { @MainActor in
            let outcome = await RemoteDownloads.download(paths: wanted) { done, total in
                toast.update(done == 0 ? RemoteCopy.downloading(total) : RemoteCopy.downloading(done: done, of: total))
            }
            if let reason = outcome.failureReason {
                toast.finish(
                    RemoteCopy.downloadFailed(done: outcome.downloaded, total: outcome.total, reason: reason), style: .error
                )
            } else {
                toast.finish(RemoteCopy.downloaded(outcome.downloaded), style: .success)
            }
        }
    }
}
