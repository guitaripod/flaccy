import BackgroundTasks
import MidgarCore
import FlaccyCore
import UIKit

/// Keeps a watch sync the person started going after they leave the app.
///
/// Preparing songs for the wrist takes real work, and WatchConnectivity only
/// carries what has been handed to it, so without this the pipeline would stall
/// the moment the app is backgrounded. iOS 26 offers a continued processing
/// task that shows its own progress and a cancel button; earlier systems get the
/// short grace period a plain background task gives.
@MainActor
final class WatchSyncBackgroundTask {

    static let shared = WatchSyncBackgroundTask()

    var onExpiration: (() -> Void)?

    private(set) var isRunning = false
    private var holder: AnyObject?
    private var legacyIdentifier: UIBackgroundTaskIdentifier = .invalid
    private var total = 0
    private var completed = 0

    private static var identifierPrefix: String {
        (Bundle.main.bundleIdentifier ?? "com.midgarcorp.flaccy") + ".watchsync."
    }

    func begin(total: Int) {
        guard !isRunning, total > 0 else { return }
        isRunning = true
        self.total = total
        completed = 0
        if #available(iOS 26.0, *) {
            Task { await requestContinuedTask(total: total) }
        } else {
            beginLegacyTask()
        }
    }

    func update(completed: Int, total: Int) {
        guard isRunning else { return }
        self.completed = completed
        self.total = total
        if #available(iOS 26.0, *), let task = holder as? BGContinuedProcessingTask {
            apply(to: task)
        }
    }

    func finish() {
        guard isRunning else { return }
        isRunning = false
        if #available(iOS 26.0, *), let task = holder as? BGContinuedProcessingTask {
            task.setTaskCompleted(success: true)
        }
        holder = nil
        endLegacyTask()
    }

    @available(iOS 26.0, *)
    private func requestContinuedTask(total: Int) async {
        let identifier = Self.identifierPrefix + UUID().uuidString
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: String(localized: "Syncing to Apple Watch"),
            subtitle: String(localized: "Preparing songs")
        )
        request.strategy = .fail
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let task = task as? BGContinuedProcessingTask else { return }
            Task { @MainActor in WatchSyncBackgroundTask.shared.adopt(task) }
        }
        guard registered else {
            MidgarLog.notice("Continued processing task was not registered; using a plain background task", category: .connectivity)
            beginLegacyTask()
            return
        }
        do {
            if #available(iOS 27.0, *) {
                try await BGTaskScheduler.shared.submitTaskRequest(request)
            } else {
                try BGTaskScheduler.shared.submit(request)
            }
            MidgarLog.info("Continued processing task submitted for \(total) songs", category: .connectivity)
        } catch {
            MidgarLog.notice("Continued processing task refused: \(error.localizedDescription)", category: .connectivity)
            beginLegacyTask()
        }
    }

    @available(iOS 26.0, *)
    private func adopt(_ task: BGContinuedProcessingTask) {
        guard isRunning else {
            task.setTaskCompleted(success: true)
            return
        }
        holder = task
        task.expirationHandler = { [weak self] in
            Task { @MainActor in self?.handleExpiration(of: task) }
        }
        apply(to: task)
        MidgarLog.info("Continued processing task started", category: .connectivity)
    }

    @available(iOS 26.0, *)
    private func apply(to task: BGContinuedProcessingTask) {
        task.progress.totalUnitCount = Int64(max(total, 1))
        task.progress.completedUnitCount = Int64(completed)
        task.updateTitle(
            String(localized: "Syncing to Apple Watch"),
            subtitle: String(localized: "\(completed) of \(total) songs")
        )
    }

    @available(iOS 26.0, *)
    private func handleExpiration(of task: BGContinuedProcessingTask) {
        MidgarLog.info("Continued processing task ended by the system or the person", category: .connectivity)
        isRunning = false
        holder = nil
        task.setTaskCompleted(success: true)
        onExpiration?()
    }

    private func beginLegacyTask() {
        guard legacyIdentifier == .invalid else { return }
        legacyIdentifier = UIApplication.shared.beginBackgroundTask(withName: "WatchSync") { [weak self] in
            Task { @MainActor in self?.handleLegacyExpiration() }
        }
    }

    private func handleLegacyExpiration() {
        endLegacyTask()
        if holder == nil {
            isRunning = false
            onExpiration?()
        }
    }

    private func endLegacyTask() {
        guard legacyIdentifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(legacyIdentifier)
        legacyIdentifier = .invalid
    }
}
