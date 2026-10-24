import FlaccyCore
import MidgarCore
import Foundation
import WatchConnectivity
import WatchKit

/// Handles the background tasks the system hands the watch app.
///
/// Apple requires that a `WKWatchConnectivityRefreshBackgroundTask` is kept
/// until the session has delivered everything pending to its delegate, and
/// completed only then: `hasContentPending` must be false and the session
/// activated. Completing earlier drops queued files and user info; never
/// completing burns the app's background budget.
@MainActor
enum WatchBackgroundTasks {

    private static var heldTasks: [WKWatchConnectivityRefreshBackgroundTask] = []
    private static var observations: [NSKeyValueObservation] = []

    static func handle(_ tasks: Set<WKRefreshBackgroundTask>) {
        WatchSyncReceiver.shared.activate()
        for task in tasks {
            if let connectivityTask = task as? WKWatchConnectivityRefreshBackgroundTask {
                heldTasks.append(connectivityTask)
                MidgarLog.info("Holding connectivity background task (\(heldTasks.count) held)", category: .connectivity)
            } else if let snapshotTask = task as? WKSnapshotRefreshBackgroundTask {
                snapshotTask.setTaskCompleted(restoredDefaultState: true, estimatedSnapshotExpiration: .distantFuture, userInfo: nil)
            } else {
                task.setTaskCompletedWithSnapshot(false)
            }
        }
        observeSessionIfNeeded()
        completeHeldTasksIfDrained()
    }

    /// Re-checks whether held tasks may finish. The receiver calls this after
    /// each delegate callback returns, because that is when content leaves the
    /// pending state.
    static func connectivityDidDeliver() {
        completeHeldTasksIfDrained()
    }

    private static func observeSessionIfNeeded() {
        guard observations.isEmpty, WCSession.isSupported() else { return }
        let session = WCSession.default
        observations = [
            session.observe(\.hasContentPending, options: []) { _, _ in
                Task { @MainActor in completeHeldTasksIfDrained() }
            },
            session.observe(\.activationState, options: []) { _, _ in
                Task { @MainActor in completeHeldTasksIfDrained() }
            },
        ]
    }

    private static func completeHeldTasksIfDrained() {
        guard !heldTasks.isEmpty, WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, !session.hasContentPending else { return }
        let finished = heldTasks
        heldTasks.removeAll()
        for task in finished { task.setTaskCompletedWithSnapshot(false) }
        MidgarLog.info("Completed \(finished.count) connectivity background tasks", category: .connectivity)
    }
}
