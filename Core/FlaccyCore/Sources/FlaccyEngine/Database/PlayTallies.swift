import Foundation
import GRDB

/// Plays counted per song and per artist, as `DatabaseManager.playTallies(since:)` folds them.
public struct PlayTallies: Sendable {
    /// Plays per `ListenHistory.trackKey` over the whole history.
    public var total: [String: Int] = [:]
    /// Plays per `ListenHistory.trackKey` since each window's start, in the order asked.
    public var since: [[String: Int]]
    /// Plays per artist as credited, lowercased.
    public var artists: [String: Int] = [:]

    init(windowCount: Int) {
        since = Array(repeating: [:], count: windowCount)
    }

    mutating func add(key: String, row: Row, windows: Int) {
        total[key, default: 0] += row["c"] as Int
        for window in 0..<windows {
            let plays: Int = row["w\(window)"] ?? 0
            if plays > 0 { since[window][key, default: 0] += plays }
        }
    }
}
