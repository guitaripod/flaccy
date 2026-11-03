import Foundation

/// Keeps the library level with its folder while the app is on screen. Files
/// arrive from outside, over a cable, from the Files app or from a computer,
/// and iOS gives an app no notification for a change anywhere under Documents,
/// so the folder is looked at on a timer. The Mac watches it with FSEvents
/// instead (`FolderWatcher`).
@MainActor
final class LibraryFolderPoller {

    private static let interval: Duration = .seconds(30)

    private var task: Task<Void, Never>?

    /// Looks now, with the revision pass, then every `interval`. A start while
    /// running begins again, so coming back to the app always looks at once.
    func start() {
        stop()
        task = Task {
            var isFirstLook = true
            while !Task.isCancelled {
                await Library.shared.rescanIfFolderChanged(checkingVersions: isFirstLook)
                isFirstLook = false
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    /// Stops looking, for the background: music can keep the app running there
    /// with nobody to show a new song to.
    func stop() {
        task?.cancel()
        task = nil
    }
}
