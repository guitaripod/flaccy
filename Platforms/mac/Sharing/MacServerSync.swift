import AppKit
import FlaccyServerEmbed
import MidgarCore

/// Ties Flaccy Server to the Mac app's moments: starts the sync engine and the shared library at launch, tells them when the app
/// comes forward or goes back, when the Mac wakes and when the library folder changes, and stops the server before the app quits.
@MainActor
final class MacServerSync {

    static let shared = MacServerSync()

    private let mergePresenter = MacServerMergePresenter()
    private var observers: [NSObjectProtocol] = []

    func start() {
        ServerSyncLifecycle.shared.launched()
        MacLibrarySharing.shared.launch()
        observe()
        if NSApp.isActive { ServerSyncLifecycle.shared.becameActive() }
    }

    func shutDown() async {
        await MacLibrarySharing.shared.shutDown()
        MidgarLog.info("The library server stopped for quit", category: .sync)
    }

    var needsGracefulShutdown: Bool {
        MacLibrarySharing.shared.isEnabled
    }

    private func observe() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                ServerSyncLifecycle.shared.becameActive()
                MacLibrarySharing.shared.refresh()
            }
        })
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ServerSyncLifecycle.shared.enteredBackground() }
        })
        observers.append(center.addObserver(forName: LibraryRoot.didChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MacLibrarySharing.shared.libraryFolderChanged() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                MidgarLog.info("The Mac woke; checking the library server", category: .sync)
                MacLibrarySharing.shared.wake()
            }
        })
    }
}
