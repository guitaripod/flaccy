import Foundation

/// What a lyrics lookup that lrclib could not answer does next.
public enum LyricsRetry: Sendable, Equatable {
    /// Ask again after this many seconds, with nothing on screen to say so.
    case quietly(after: TimeInterval)
    /// Put the failure in front of the listener, then ask again after this many
    /// seconds. Happens once per lookup.
    case show(after: TimeInterval)
    /// Asking again cannot help: say why and stop.
    case giveUp
}

/// How long a failed lookup stays out of sight before the listener hears of it.
/// Mirrored in Rust as `linux/shared/src/lyrics/patience.rs`.
public enum LyricsPatience {

    /// Seconds to wait after the first, second, third and fourth failure in a
    /// row before asking again, saying nothing meanwhile. About 76 seconds in
    /// all, which is longer than most lrclib hiccups last.
    public static let quietDelays: [TimeInterval] = [3, 8, 20, 45]

    /// Seconds between the later attempts, after the failure has been shown:
    /// the lyrics appear on their own once lrclib is back.
    public static let slowDelay: TimeInterval = 60

    /// Whether the next question to lrclib is worth asking after this answer.
    /// lrclib gives up on a question it cannot answer from memory within about
    /// half a second with a 503 and keeps working on it, so a 503 says nothing
    /// about the plainer questions that follow it: the same song asked without
    /// its album, or searched for, is often answered straight away. Anything
    /// else (no connection, a timeout, a refusal, a 500 or 502) says the server
    /// is not answering at all.
    public static func triesNextQuestion(after failure: LyricsFailure) -> Bool {
        failure == .server(503)
    }

    /// What to do after the `failures`-th failure in a row (1 for the first).
    /// `cooldownLeft` is how long the shared lrclib gate is still holding
    /// requests back, which no retry may undercut.
    public static func next(
        after failure: LyricsFailure, failures: Int, cooldownLeft: TimeInterval = 0
    ) -> LyricsRetry {
        if case .rejected = failure { return .giveUp }
        let hold = max(cooldownLeft, 0)
        let count = max(failures, 1)
        if count <= quietDelays.count {
            return .quietly(after: max(quietDelays[count - 1], hold))
        }
        if count == quietDelays.count + 1 {
            return .show(after: max(slowDelay, hold))
        }
        return .quietly(after: max(slowDelay, hold))
    }
}
