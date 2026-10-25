import Foundation

/// One play as Home's history cards read it.
public struct HomePlay: Equatable, Sendable {
    public var album: String
    public var artist: String
    public var at: Date
    public var seconds: Int

    public init(album: String, artist: String, at: Date, seconds: Int) {
        self.album = album
        self.artist = artist
        self.at = at
        self.seconds = seconds
    }

    /// Plays stamped before 2002-01-01 UTC carry an old scrobbler's zero
    /// date and belong to no day.
    public static let earliestDated = Date(timeIntervalSince1970: 1_009_843_200)

    public var isDated: Bool {
        at >= Self.earliestDated
    }
}

/// The album On This Day offers: the one played most on today's date in an
/// earlier year, or failing that, around this date a year ago.
public struct OnThisDayPick: Equatable, Sendable {

    public enum Kind: Equatable, Sendable {
        case sameDay
        case yearAgoThisWeek
    }

    public var kind: Kind
    public var album: String
    public var artist: String
    public var year: Int
    public var plays: Int
    public var lastPlayedAt: Date
}

public enum OnThisDay {

    /// Fewer plays than this is a song passing by, not an album that day.
    public static let minimumPlays = 3
    /// How many days either side of a year ago still count as "this week".
    public static let weekSpanDays = 3

    public static func pick(_ plays: [HomePlay], now: Date, calendar: Calendar) -> OnThisDayPick? {
        let today = calendar.dateComponents([.year, .month, .day], from: now)
        let sameDay = plays.filter { play in
            guard play.isDated, !HomeKeys.fold(play.album).isEmpty else { return false }
            let parts = calendar.dateComponents([.year, .month, .day], from: play.at)
            return parts.month == today.month && parts.day == today.day && (parts.year ?? 0) < (today.year ?? 0)
        }
        if let best = strongest(sameDay, kind: .sameDay, byYear: true, calendar: calendar) { return best }

        guard let yearAgo = calendar.date(byAdding: .year, value: -1, to: now) else { return nil }
        let anchor = calendar.startOfDay(for: yearAgo)
        let week = plays.filter { play in
            guard play.isDated, !HomeKeys.fold(play.album).isEmpty else { return false }
            let day = calendar.startOfDay(for: play.at)
            let offset = calendar.dateComponents([.day], from: anchor, to: day).day ?? Int.max
            return abs(offset) <= weekSpanDays
        }
        return strongest(week, kind: .yearAgoThisWeek, byYear: false, calendar: calendar)
    }

    /// The group with the most plays (at least `minimumPlays`), ties going to
    /// the more recent last play, then to the smaller key. Display names come
    /// from the group's latest play.
    private static func strongest(
        _ plays: [HomePlay],
        kind: OnThisDayPick.Kind,
        byYear: Bool,
        calendar: Calendar
    ) -> OnThisDayPick? {
        var groups: [String: (count: Int, latest: HomePlay)] = [:]
        for play in plays {
            let year = calendar.component(.year, from: play.at)
            let key = (byYear ? "\(year)" : "") + HomeKeys.separator + HomeKeys.album(title: play.album, credit: play.artist)
            if let existing = groups[key] {
                groups[key] = (existing.count + 1, play.at > existing.latest.at ? play : existing.latest)
            } else {
                groups[key] = (1, play)
            }
        }
        let best = groups
            .filter { $0.value.count >= minimumPlays }
            .sorted { lhs, rhs in
                if lhs.value.count != rhs.value.count { return lhs.value.count > rhs.value.count }
                if lhs.value.latest.at != rhs.value.latest.at { return lhs.value.latest.at > rhs.value.latest.at }
                return lhs.key < rhs.key
            }
            .first
        guard let best else { return nil }
        return OnThisDayPick(
            kind: kind,
            album: best.value.latest.album,
            artist: best.value.latest.artist,
            year: calendar.component(.year, from: best.value.latest.at),
            plays: best.value.count,
            lastPlayedAt: best.value.latest.at
        )
    }
}

/// This Week on Home: the rolling seven days against the seven before, and
/// plays per calendar day for the spark, today last.
public struct WeekGlance: Equatable, Sendable {
    public var plays: Int
    public var seconds: Int
    public var previousPlays: Int
    public var previousSeconds: Int
    public var daily: [Int]

    public static let window: TimeInterval = 7 * 86_400
    public static let days = 7

    public var playsDelta: PeriodDelta {
        .compare(current: plays, previous: previousPlays)
    }

    public var secondsDelta: PeriodDelta {
        .compare(current: seconds, previous: previousSeconds)
    }

    public var hasPlays: Bool {
        plays > 0 || previousPlays > 0
    }

    /// The busiest day of the spark, the latest when days tie; none when
    /// nothing was played.
    public var peakIndex: Int? {
        guard let peak = daily.max(), peak > 0 else { return nil }
        return daily.lastIndex(of: peak)
    }

    /// Whole hours and the minutes after them, both truncated.
    public static func hoursAndMinutes(_ seconds: Int) -> (hours: Int, minutes: Int) {
        let clamped = max(seconds, 0)
        return (clamped / 3600, (clamped % 3600) / 60)
    }

    /// Current window `[now - 7 d, now]`, previous `[now - 14 d, now - 7 d)`.
    public static func compute(_ plays: [HomePlay], now: Date, calendar: Calendar) -> WeekGlance {
        let currentStart = now.addingTimeInterval(-window)
        let previousStart = now.addingTimeInterval(-2 * window)
        let today = calendar.startOfDay(for: now)
        var glance = WeekGlance(plays: 0, seconds: 0, previousPlays: 0, previousSeconds: 0, daily: Array(repeating: 0, count: days))
        for play in plays where play.isDated && play.at <= now {
            if play.at >= currentStart {
                glance.plays += 1
                glance.seconds += max(play.seconds, 0)
            } else if play.at >= previousStart {
                glance.previousPlays += 1
                glance.previousSeconds += max(play.seconds, 0)
            }
            let offset = calendar.dateComponents([.day], from: calendar.startOfDay(for: play.at), to: today).day ?? Int.max
            if (0..<days).contains(offset) {
                glance.daily[days - 1 - offset] += 1
            }
        }
        return glance
    }
}
