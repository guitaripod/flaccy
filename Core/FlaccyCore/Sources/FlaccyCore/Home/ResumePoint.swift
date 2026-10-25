import Foundation

/// Where a paused session stands inside its queue: which track, how far into
/// it, and how long everything still to come lasts.
public struct ResumePoint: Equatable, Sendable {
    public var trackIndex: Int
    public var elapsed: Double
    public var durations: [Double]
    public var savedAt: Date

    /// A session older than this is history, not something to pick up.
    public static let maximumAge: TimeInterval = 14 * 86_400
    /// The last track counts as heard when less than this remains.
    public static let finishMargin: Double = 10
    /// More tracks than this draw one continuous bar instead of segments.
    public static let maximumSegments = 24

    public init(trackIndex: Int, elapsed: Double, durations: [Double], savedAt: Date) {
        self.trackIndex = trackIndex
        self.elapsed = elapsed
        self.durations = durations
        self.savedAt = savedAt
    }

    public var trackCount: Int {
        durations.count
    }

    public var currentDuration: Double {
        durations.indices.contains(trackIndex) ? durations[trackIndex] : 0
    }

    public var fractionInTrack: Double {
        guard currentDuration > 0 else { return 0 }
        return min(max(elapsed / currentDuration, 0), 1)
    }

    public var remainingSeconds: Double {
        guard durations.indices.contains(trackIndex) else { return 0 }
        let rest = durations[(trackIndex + 1)...].reduce(0, +)
        return max(currentDuration - elapsed, 0) + rest
    }

    public var isFinished: Bool {
        guard durations.indices.contains(trackIndex) else { return true }
        return trackIndex == durations.count - 1 && currentDuration - elapsed < Self.finishMargin
    }

    public func isResumable(now: Date) -> Bool {
        !isFinished && now.timeIntervalSince(savedAt) <= Self.maximumAge
    }

    /// One fill fraction per track (1 heard, 0 to come, the current one
    /// partly), or a single segment holding the share of time already played
    /// when the queue is too long to segment.
    public func segments() -> [Double] {
        guard durations.indices.contains(trackIndex) else { return [] }
        guard durations.count <= Self.maximumSegments else {
            let total = durations.reduce(0, +)
            guard total > 0 else { return [0] }
            return [min(max((total - remainingSeconds) / total, 0), 1)]
        }
        return durations.indices.map { index in
            if index < trackIndex { return 1 }
            if index > trackIndex { return 0 }
            return fractionInTrack
        }
    }
}

/// How long ago a session was paused, in the words Home uses for it.
/// `weekday` follows `Calendar`: 1 is Sunday.
public enum ResumeRecency: Equatable, Sendable {
    case justNow
    case earlierToday
    case lastNight
    case yesterday
    case weekday(Int)
    case date(Date)

    public static let justNowWindow: TimeInterval = 15 * 60
    public static let eveningStartsHour = 18
    public static let nightEndsHour = 5

    public static func of(_ savedAt: Date, now: Date, calendar: Calendar) -> ResumeRecency {
        if now.timeIntervalSince(savedAt) < justNowWindow { return .justNow }
        let savedDay = calendar.startOfDay(for: savedAt)
        let today = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: savedDay, to: today).day ?? 0
        let savedHour = calendar.component(.hour, from: savedAt)
        switch days {
        case ...0:
            let nowHour = calendar.component(.hour, from: now)
            return savedHour < nightEndsHour && nowHour >= nightEndsHour ? .lastNight : .earlierToday
        case 1:
            return savedHour >= eveningStartsHour ? .lastNight : .yesterday
        case 2...6:
            return .weekday(calendar.component(.weekday, from: savedAt))
        default:
            return .date(savedAt)
        }
    }
}
