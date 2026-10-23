import FlaccyCore
import SwiftUI
import WatchKit

/// Installs the WCSession delegate the moment the process launches — including
/// background launches for queued file/command delivery, where the SwiftUI
/// view hierarchy (and its `.task`) may never appear.
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() {
        FlaccyLogging.configure()
        WatchSyncReceiver.shared.activate()
    }

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        WatchBackgroundTasks.handle(backgroundTasks)
    }
}

@main
struct FlaccyWatchApp: App {

    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var appDelegate

    @State private var store = WatchLibraryStore(documentsDirectory: AppPaths.documents)
    @State private var player = WatchAudioPlayer(documentsDirectory: AppPaths.documents)
    @Environment(\.scenePhase) private var scenePhase

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
                    restoreLastSession()
                    #if DEBUG && targetEnvironment(simulator)
                    WatchReceiveExercise.runIfRequested()
                    #endif
                }
                .onChange(of: scenePhase) {
                    if scenePhase == .background { player.persistSession(immediately: true) }
                }
        }
    }

    /// Brings back the queue and position the person left, paused, once the
    /// library can say which of those tracks are still on the watch.
    private func restoreLastSession() {
        guard let snapshot = PlaybackSessionStore.shared.load() else { return }
        player.restore(from: snapshot, in: store.allTracks)
        #if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--shot-resume") { player.resumePlayback() }
        #endif
    }
}

enum AppPaths {
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
}
