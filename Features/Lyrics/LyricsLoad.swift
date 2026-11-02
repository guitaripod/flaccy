import Foundation

/// A lyrics lookup a view is waiting on. It goes on, quietly retrying, for as
/// long as the view holds it, and ends when the view starts another lookup or
/// goes away, so a view that was closed never keeps asking lrclib.
nonisolated final class LyricsLoad: Sendable {

    private let task: Task<Void, Never>

    init(_ task: Task<Void, Never>) {
        self.task = task
    }

    deinit {
        task.cancel()
    }
}
