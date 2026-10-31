import Foundation

/// Waits for an async value no longer than a limit.
///
/// When the limit passes first the operation is cancelled but never awaited,
/// so work stuck inside a framework that ignores cancellation (a decoder
/// wedged on one malformed file) cannot hold its caller, and a library scan
/// waiting on it always finishes.
public enum Deadline {

    public static func value<Value: Sendable>(
        within limit: Duration,
        _ operation: @escaping @Sendable () async -> Value
    ) async -> Value? {
        await withCheckedContinuation { continuation in
            let race = DeadlineRace(continuation)
            race.track(Task { race.settle(await operation()) })
            race.track(Task {
                try? await Task.sleep(for: limit)
                guard !Task.isCancelled else { return }
                race.settle(nil)
            })
        }
    }
}

/// The two sides of one `Deadline` wait: whichever settles first resumes the
/// caller, and both tasks are cancelled, so a finished read stops its timer
/// and an expired timer abandons its read.
private final class DeadlineRace<Value: Sendable>: @unchecked Sendable {

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value?, Never>?
    private var contenders: [Task<Void, Never>] = []

    init(_ continuation: CheckedContinuation<Value?, Never>) {
        self.continuation = continuation
    }

    func track(_ task: Task<Void, Never>) {
        let settled = lock.withLock { () -> Bool in
            guard continuation != nil else { return true }
            contenders.append(task)
            return false
        }
        if settled { task.cancel() }
    }

    func settle(_ value: Value?) {
        let (waiting, tasks) = lock.withLock { () -> (CheckedContinuation<Value?, Never>?, [Task<Void, Never>]) in
            defer {
                continuation = nil
                contenders = []
            }
            return (continuation, contenders)
        }
        guard let waiting else { return }
        tasks.forEach { $0.cancel() }
        waiting.resume(returning: value)
    }
}
