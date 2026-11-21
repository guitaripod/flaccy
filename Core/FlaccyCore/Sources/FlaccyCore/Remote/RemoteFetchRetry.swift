import Foundation

/// How long a streamed song keeps trying after its connection to the server drops, and how often the player
/// rebuilds a song that failed anyway.
///
/// A phone changes network, a tunnel reconnects and a server restarts in seconds, so a fetch that fails for a
/// reason that can pass is tried again after each of `delays` (about half a minute in all) before the song is
/// given up. Progress between two failures starts the count over.
public enum RemoteFetchRetry {

    public static let delays: [TimeInterval] = [0.5, 1, 2, 4, 8, 8, 8]

    /// How many times the player builds a failed song again, from where it stopped, before moving on.
    public static let itemRecoveries = 3

    /// The wait before the next try after the `failures`th failure in a row, nil when the song is given up.
    public static func delay(afterFailures failures: Int) -> TimeInterval? {
        guard failures >= 1, failures <= delays.count else { return nil }
        return delays[failures - 1]
    }

    /// Whether an HTTP status is worth another try: the server or a proxy in front of it failing, or asking to wait.
    public static func isTransient(httpStatus status: Int) -> Bool {
        status == 408 || status == 425 || status == 429 || (500...599).contains(status)
    }

    /// The wait before a failed preloaded song is built again, growing with each attempt.
    public static func preloadDelay(attempt: Int) -> TimeInterval {
        2 * TimeInterval(max(1, attempt))
    }
}
