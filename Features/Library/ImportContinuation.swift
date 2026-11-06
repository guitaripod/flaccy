import MidgarCore
import UIKit

/// Carries running imports through the background on one continued processing task, so a big copy from iCloud Drive
/// or a network share keeps going after the person leaves the app, with the system's own progress and Cancel.
///
/// Imports can overlap (a Files pick while Wi-Fi Transfer delivers a drop), so the task shows their combined count and
/// ends when the last one does. When the system or the person ends the task while the app is away, every running import
/// stops after the song it is copying; the outcome says how many were left, and the same pick run again copies only
/// those. A plain background task's grace period running out stops nothing: the app is suspended and the copy picks up
/// where it was when the person returns.
@MainActor
final class ImportContinuation {

    static let shared = ImportContinuation()

    private struct Running {
        let stop: ImportStop
        var done = 0
        var total = 0
    }

    private let work: ContinuedWork
    private var running: [ObjectIdentifier: Running] = [:]
    private var settled = 0
    private var stoppedThisRun = false

    init(work: ContinuedWork = .libraryImport) {
        self.work = work
        work.onExpiration = { [weak self] expiry in self?.expired(expiry) }
    }

    func started(_ stop: ImportStop) {
        running[ObjectIdentifier(stop)] = Running(stop: stop)
    }

    func progressed(_ stop: ImportStop, _ progress: LibraryImportProgress) {
        guard case .copying(let done, let total) = progress, running[ObjectIdentifier(stop)] != nil else { return }
        running[ObjectIdentifier(stop)]?.done = done
        running[ObjectIdentifier(stop)]?.total = total
        report()
    }

    /// An import that ends while others still run stays in the count as done, so the system's progress never goes
    /// backwards; the count starts over once the last one ends.
    func ended(_ stop: ImportStop) {
        guard let finished = running.removeValue(forKey: ObjectIdentifier(stop)) else { return }
        if running.isEmpty {
            settled = 0
            stoppedThisRun = false
            work.finish()
        } else {
            settled += finished.total
            report()
        }
    }

    /// Asks for the background task only for imports still meant to run: once the person or the system ended it
    /// while the app was away, the imports it stopped do not ask again.
    private func report() {
        let total = settled + running.values.reduce(0) { $0 + $1.total }
        let done = settled + running.values.reduce(0) { $0 + $1.done }
        guard total > 0 else { return }
        if !work.isRunning {
            guard !stoppedThisRun else { return }
            work.begin(total: total)
        }
        work.update(completed: done, total: total)
    }

    /// Only the continued processing task carries a Cancel, and only while the app is away does ending it mean the
    /// person (or the system on their behalf) wants the copy to stop; in front, the import simply carries on.
    private func expired(_ expiry: ContinuedWork.Expiry) {
        guard expiry == .continuedTask, UIApplication.shared.applicationState != .active else { return }
        MidgarLog.info("Stopping \(running.count) imports: their background task ended", category: .content)
        stoppedThisRun = true
        running.values.forEach { $0.stop.request() }
    }
}
