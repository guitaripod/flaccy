import Foundation

/// Decides whether a play on the watch happened, from nothing but the clock
/// readings the player reports. It holds no timers and no platform types, so
/// every rule is testable with plain numbers.
///
/// Only forward progress that plausibly came from playing counts: a seek moves
/// the position by more than `maxCreditedStep`, and a pause moves it not at all,
/// so neither adds listening time.
public struct WatchPlayTracker: Sendable, Equatable {

    public static let maxCreditedStep: TimeInterval = 2

    private struct Play: Sendable, Equatable {
        let path: String
        let title: String
        let artist: String
        let album: String
        let duration: TimeInterval
        let startedAt: Date
        var playedSeconds: TimeInterval = 0
        var lastElapsed: TimeInterval = 0
    }

    private var current: Play?

    public init() {}

    public var isTracking: Bool { current != nil }

    public var playedSeconds: TimeInterval { current?.playedSeconds ?? 0 }

    /// Starts counting a fresh play. Whatever was being counted before is
    /// dropped, so a caller that wants it judged calls `finish(now:)` first.
    public mutating func begin(
        path: String,
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval,
        at date: Date
    ) {
        current = Play(
            path: path,
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            startedAt: date
        )
    }

    public mutating func advance(to elapsed: TimeInterval, isPlaying: Bool) {
        guard var play = current, elapsed.isFinite else { return }
        let step = elapsed - play.lastElapsed
        if isPlaying, step > 0, step <= Self.maxCreditedStep {
            play.playedSeconds += step
        }
        play.lastElapsed = elapsed
        current = play
    }

    /// Ends the play. It yields an entry only when the listening qualifies, and
    /// never twice for the same `begin`.
    public mutating func finish(now: Date) -> WatchPlayEntry? {
        guard let play = current else { return nil }
        current = nil
        guard WatchPlayRule.qualifies(playedSeconds: play.playedSeconds, trackDuration: play.duration) else { return nil }
        return WatchPlayEntry(
            path: play.path,
            title: play.title,
            artist: play.artist,
            album: play.album,
            startedAt: play.startedAt,
            durationSeconds: Int(play.duration.rounded())
        )
    }
}
