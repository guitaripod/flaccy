import BackgroundTasks
import MidgarCore
import FlaccyCore
import UIKit

/// Keeps work the person started going after they leave the app: a watch sync, or an import of their music.
///
/// iOS 26 offers a continued processing task that shows its own progress and a cancel button; earlier systems get the
/// short grace period a plain background task gives, after which the app is suspended and the work picks up again when
/// the person comes back.
@MainActor
final class ContinuedWork {

    /// How the background time ran out: the continued processing task was ended by the system or by the person, or a
    /// plain background task's grace period ran out and the app is about to be suspended.
    enum Expiry {
        case continuedTask
        case gracePeriod
    }

    static let watchSync = ContinuedWork(
        suffix: "watchsync",
        legacyName: "WatchSync",
        category: .connectivity,
        title: { String(localized: "Syncing to Apple Watch") },
        startingSubtitle: { String(localized: "Preparing songs") },
        progressSubtitle: { completed, total in String(localized: "\(completed) of \(total) songs") }
    )

    static let libraryImport = ContinuedWork(
        suffix: "import",
        legacyName: "LibraryImport",
        category: .content,
        title: { String(localized: "Adding music to Flaccy") },
        startingSubtitle: { String(localized: "Copying songs") },
        progressSubtitle: { completed, total in String(localized: "\(completed) of \(total) songs") }
    )

    var onExpiration: ((Expiry) -> Void)?

    private(set) var isRunning = false
    private var holder: AnyObject?
    private var legacyIdentifier: UIBackgroundTaskIdentifier = .invalid
    private var legacyToken: UUID?
    private var run = 0
    private var pendingIdentifier: String?
    private var total = 0
    private var completed = 0

    private let suffix: String
    private let legacyName: String
    private let category: MidgarLog.Category
    private let title: () -> String
    private let startingSubtitle: () -> String
    private let progressSubtitle: (Int, Int) -> String

    private init(
        suffix: String,
        legacyName: String,
        category: MidgarLog.Category,
        title: @escaping () -> String,
        startingSubtitle: @escaping () -> String,
        progressSubtitle: @escaping (Int, Int) -> String
    ) {
        self.suffix = suffix
        self.legacyName = legacyName
        self.category = category
        self.title = title
        self.startingSubtitle = startingSubtitle
        self.progressSubtitle = progressSubtitle
    }

    private var identifierPrefix: String {
        (Bundle.main.bundleIdentifier ?? "com.midgarcorp.flaccy") + ".\(suffix)."
    }

    func begin(total: Int) {
        guard !isRunning, total > 0 else { return }
        isRunning = true
        run += 1
        self.total = total
        completed = 0
        if #available(iOS 26.0, *) {
            let run = run
            Task { await requestContinuedTask(total: total, run: run) }
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
        pendingIdentifier = nil
        if #available(iOS 26.0, *), let task = holder as? BGContinuedProcessingTask {
            task.setTaskCompleted(success: true)
        }
        holder = nil
        endLegacyTask()
    }

    /// Asks for the task of one run. A run that finished before its request went out sends none, and whichever
    /// request is the current run's is the only task `adopt` keeps.
    @available(iOS 26.0, *)
    private func requestContinuedTask(total: Int, run: Int) async {
        guard isRunning, run == self.run else { return }
        let identifier = identifierPrefix + UUID().uuidString
        pendingIdentifier = identifier
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: title(),
            subtitle: startingSubtitle()
        )
        request.strategy = .fail
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            self?.adopt(task)
        }
        guard registered else {
            MidgarLog.notice("Continued processing task was not registered; using a plain background task", category: category)
            if isRunning, run == self.run { beginLegacyTask() }
            return
        }
        do {
            if #available(iOS 27.0, *) {
                try await BGTaskScheduler.shared.submitTaskRequest(request)
            } else {
                try BGTaskScheduler.shared.submit(request)
            }
            MidgarLog.info("Continued processing task submitted for \(total) songs", category: category)
        } catch {
            MidgarLog.notice("Continued processing task refused: \(error.localizedDescription)", category: category)
            if isRunning, run == self.run { beginLegacyTask() }
        }
    }

    /// Takes over the continued processing task the system launched for this work, and completes at once a task
    /// launched for a run that already finished.
    ///
    /// The scheduler runs the launch handler on the queue it was registered with, the main queue here: the handler is
    /// formed on the main actor, and Swift 6 traps the moment such a closure runs on any other queue.
    @available(iOS 26.0, *)
    private func adopt(_ task: BGTask) {
        guard let task = task as? BGContinuedProcessingTask else { return }
        guard isRunning, task.identifier == pendingIdentifier else {
            task.setTaskCompleted(success: true)
            return
        }
        holder = task
        task.expirationHandler = Self.expirationRelay(for: task.identifier, to: self)
        apply(to: task)
        MidgarLog.info("Continued processing task started", category: category)
    }

    @available(iOS 26.0, *)
    private func apply(to task: BGContinuedProcessingTask) {
        task.progress.totalUnitCount = Int64(max(total, 1))
        task.progress.completedUnitCount = Int64(completed)
        task.updateTitle(title(), subtitle: progressSubtitle(completed, total))
    }

    /// The handler the system calls when it or the person ends the task. It runs on a queue of the system's choosing,
    /// so it carries no actor isolation and hops to the main actor before touching any state.
    @available(iOS 26.0, *)
    private nonisolated static func expirationRelay(for identifier: String, to work: ContinuedWork) -> @Sendable () -> Void {
        { [weak work] in
            Task { @MainActor in work?.handleExpiration(of: identifier) }
        }
    }

    @available(iOS 26.0, *)
    private func handleExpiration(of identifier: String) {
        guard let task = holder as? BGContinuedProcessingTask, task.identifier == identifier else { return }
        MidgarLog.info("Continued processing task ended by the system or the person", category: category)
        isRunning = false
        holder = nil
        pendingIdentifier = nil
        task.setTaskCompleted(success: true)
        onExpiration?(.continuedTask)
    }

    private func beginLegacyTask() {
        guard legacyIdentifier == .invalid else { return }
        let token = UUID()
        legacyToken = token
        legacyIdentifier = UIApplication.shared.beginBackgroundTask(withName: legacyName) { [weak self] in
            Task { @MainActor in self?.handleLegacyExpiration(of: token) }
        }
    }

    /// Acts only for the plain background task still held: an expiry that reaches the main actor after that task was
    /// ended and a new run began belongs to nobody.
    private func handleLegacyExpiration(of token: UUID) {
        guard token == legacyToken else { return }
        endLegacyTask()
        if holder == nil {
            isRunning = false
            onExpiration?(.gracePeriod)
        }
    }

    private func endLegacyTask() {
        guard legacyIdentifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(legacyIdentifier)
        legacyIdentifier = .invalid
        legacyToken = nil
    }
}
