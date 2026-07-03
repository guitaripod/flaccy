import FlaccyCore
import SwiftUI
import WatchKit

/// Installs the WCSession delegate the moment the process launches — including
/// background launches for queued file/command delivery, where the SwiftUI
/// view hierarchy (and its `.task`) may never appear.
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() {
        WatchSyncReceiver.shared.activate()
    }
}

@main
struct FlaccyWatchApp: App {

    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var appDelegate

    @State private var store = WatchLibraryStore(documentsDirectory: AppPaths.documents)
    @State private var player = WatchAudioPlayer(documentsDirectory: AppPaths.documents)

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(player)
                .environment(WatchSyncReceiver.shared.status)
                .tint(WatchTheme.accent)
                .task {
                    WatchSyncReceiver.shared.onLibraryChanged = { [store] in
                        Task { @MainActor in store.reload() }
                    }
                    WatchSyncReceiver.shared.activate()
                    await store.load()
                }
        }
    }
}

enum AppPaths {
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
}
