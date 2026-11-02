import Foundation

/// Where a song stands against the listener's habits and the queue. Mirrored in
/// Rust as `Candidate` in `linux/shared/src/precache.rs`.
public struct PrecacheCandidate: Sendable, Equatable {
    public var key: String
    /// Places ahead of the playing song, nil when it is not queued.
    public var queueDistance: Int?
    /// Another track of the album that is playing.
    public var albumSibling: Bool
    public var plays30Days: Int
    public var playsTotal: Int
    public var daysSincePlayed: Double?
    public var daysSinceAdded: Double

    public init(
        key: String, queueDistance: Int? = nil, albumSibling: Bool = false,
        plays30Days: Int = 0, playsTotal: Int = 0,
        daysSincePlayed: Double? = nil, daysSinceAdded: Double
    ) {
        self.key = key
        self.queueDistance = queueDistance
        self.albumSibling = albumSibling
        self.plays30Days = plays30Days
        self.playsTotal = playsTotal
        self.daysSincePlayed = daysSincePlayed
        self.daysSinceAdded = daysSinceAdded
    }
}

/// Why a piece of preparation failed, which decides how long to leave it.
public enum PrecacheFailure: Sendable, Equatable {
    /// The network or the server hiccuped.
    case transient
    /// The server is up and answered "busy" to this one question: it gives up
    /// on what it cannot answer from memory within moments and keeps working
    /// on it, so the same question a little later is usually answered.
    case busy
    /// The server asked for fewer requests.
    case throttled
    /// The server refuses this client.
    case blocked
    /// There is nothing to prepare: no video, no lyrics.
    case notFound
    /// This file will never play here.
    case permanent
}

/// What Flaccy prepares ahead of time and how long it leaves a failure alone.
/// Pure functions over plain values. Mirrored in Rust as
/// `linux/shared/src/precache.rs`.
public enum PrecachePlan {

    /// Entries ahead of the playing one whose lyrics are fetched.
    public static let lyricsQueueDepth = 50

    /// The songs whose lyrics to fetch, most wanted first. With `wholeLibrary`
    /// every song is eventually asked about; without, only the queue and what
    /// the listener plays.
    public static func lyricsOrder(_ candidates: [PrecacheCandidate], wholeLibrary: Bool) -> [String] {
        var scored: [(score: Double, key: String)] = []
        for candidate in candidates {
            let nearby = candidate.queueDistance.flatMap { $0 <= lyricsQueueDepth ? $0 : nil }
            let played = candidate.plays30Days >= 1 || candidate.playsTotal >= 3
            if nearby == nil && !played && !candidate.albumSibling && !wholeLibrary { continue }
            let queueBonus = nearby.map { 100.0 / (1.0 + Double($0)) } ?? 0
            let fresh = candidate.daysSinceAdded <= 14 ? 5.0 : 0
            let score = queueBonus
                + 10 * log(1 + Double(candidate.plays30Days))
                + 3 * log(1 + Double(candidate.playsTotal))
                + fresh
                + (candidate.albumSibling ? 8 : 0)
            scored.append((score, candidate.key))
        }
        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.key.utf8.lexicographicallyPrecedes(rhs.key.utf8)
        }
        return scored.map(\.key)
    }

    /// Seconds to leave a failure alone after its `attempts`-th occurrence.
    /// `jitter` is a number in [0, 1) that spreads retries by up to 30 % so a
    /// batch that failed together does not retry together.
    public static func retryDelaySeconds(_ failure: PrecacheFailure, attempts: Int, jitter: Double) -> Int {
        func doubling(_ base: Int, _ cap: Int) -> Int {
            let exponent = min(max(attempts - 1, 0), 16)
            return min(base << exponent, cap)
        }
        let base: Int
        switch failure {
        case .transient, .busy: base = doubling(30, 60 * 60)
        case .throttled: base = doubling(5 * 60, 6 * 60 * 60)
        case .blocked: base = doubling(30 * 60, 24 * 60 * 60)
        case .notFound: base = 7 * 24 * 60 * 60
        case .permanent: base = 30 * 24 * 60 * 60
        }
        return Int(Double(base) * (1 + 0.3 * min(max(jitter, 0), 1)))
    }
}

/// The songs a lane tried and could not finish, with when each may be tried
/// again. Mirrored in Rust as `RetryLedger`.
public struct PrecacheRetryLedger: Sendable {

    private struct Entry: Sendable {
        var attempts: Int
        var due: Date
    }

    private var entries: [String: Entry] = [:]

    public init() {}

    /// Notes a failure: the song waits `retryDelaySeconds` for its
    /// `attempts`-th failure in a row before it is tried again.
    public mutating func failed(_ key: String, _ failure: PrecacheFailure, now: Date, jitter: Double) {
        let attempts = (entries[key]?.attempts ?? 0) + 1
        let wait = PrecachePlan.retryDelaySeconds(failure, attempts: attempts, jitter: jitter)
        entries[key] = Entry(attempts: attempts, due: now.addingTimeInterval(TimeInterval(wait)))
    }

    /// The song was prepared: whatever kept it waiting is forgotten.
    public mutating func succeeded(_ key: String) {
        entries[key] = nil
    }

    /// Whether the song is still being left alone at `now`.
    public func isWaiting(_ key: String, now: Date) -> Bool {
        entries[key].map { $0.due > now } ?? false
    }

    /// How many songs are still being left alone.
    public func waiting(now: Date) -> Int {
        entries.values.filter { $0.due > now }.count
    }

    /// When the first waiting song may be tried again.
    public func nextDue(now: Date) -> Date? {
        entries.values.map(\.due).filter { $0 > now }.min()
    }
}
