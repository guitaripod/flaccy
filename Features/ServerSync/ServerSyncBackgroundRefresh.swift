import BackgroundTasks
import Foundation
import MidgarCore

/// The system's periodic wake-up for sync: a `BGAppRefreshTask` that runs one round while the app is not on screen, so a
/// playlist changed on another device is already here when the app opens. Registered at launch, scheduled whenever the app
/// goes to the background and after each run, and only while a server is connected.
nonisolated enum ServerSyncBackgroundRefresh {

    static let interval: TimeInterval = 15 * 60

    static var identifier: String {
        (Bundle.main.bundleIdentifier ?? "com.midgarcorp.flaccy") + ".serversync"
    }

    static func register() {
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            ServerSyncBackgroundRefresh.run(task)
        }
        if !registered { MidgarLog.error("The sync refresh task could not be registered", category: .sync) }
    }

    static func schedule() {
        guard ServerSyncService.engine.connectedServer != nil else { return }
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            MidgarLog.notice("The sync refresh task was not scheduled: \(error.localizedDescription)", category: .sync)
        }
    }

    private static func run(_ task: BGTask) {
        let handle = TaskHandle(task: task)
        let work = Task {
            let succeeded = await ServerSyncService.engine.performBackgroundRefresh()
            ServerSyncBackgroundRefresh.schedule()
            handle.task.setTaskCompleted(success: succeeded)
        }
        task.expirationHandler = { work.cancel() }
    }

    /// `BGTask` is handed to one closure at a time here: the system's callback, then the refresh task, which completes it once.
    private struct TaskHandle: @unchecked Sendable {
        let task: BGTask
    }
}
