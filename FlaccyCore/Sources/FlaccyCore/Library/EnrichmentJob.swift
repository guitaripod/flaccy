import Foundation

/// The kinds of entity the enrichment job settles, each with its own producer
/// version and its own patience.
public enum EnrichmentScope: String, Codable, Sendable, CaseIterable {
    case album, artist, aiBatch

    /// Bumping this revives `exhausted` and `partial` records for the scope
    /// without touching entities that already have everything they need.
    public var currentVersion: Int {
        switch self {
        case .album: return 1
        case .artist: return 1
        case .aiBatch: return 1
        }
    }

    public var maxAttempts: Int {
        switch self {
        case .album: return 4
        case .artist: return 3
        case .aiBatch: return 3
        }
    }
}

public enum EnrichmentStatus: Int, Codable, Sendable {
    case pending = 0
    case satisfied = 1
    case exhausted = 2
    case partial = 3
}

public enum EnrichmentFailure: String, Codable, Sendable {
    case transport
    case notFound
    case rateLimited
    case unauthorized
}

public struct EnrichmentFields: OptionSet, Codable, Sendable, Equatable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let cover       = EnrichmentFields(rawValue: 1 << 0)
    public static let year        = EnrichmentFields(rawValue: 1 << 1)
    public static let genre       = EnrichmentFields(rawValue: 1 << 2)
    public static let mbid        = EnrichmentFields(rawValue: 1 << 3)
    public static let artistBio   = EnrichmentFields(rawValue: 1 << 4)
    public static let artistImage = EnrichmentFields(rawValue: 1 << 5)
    public static let identified  = EnrichmentFields(rawValue: 1 << 6)

    /// What must be present for an entity to be settled. Genre is deliberately
    /// excluded: MusicBrainz routinely returns an empty tag array, so requiring
    /// it makes a correctly-tagged album unsatisfiable forever.
    public static func required(for scope: EnrichmentScope) -> EnrichmentFields {
        switch scope {
        case .album: return [.cover, .year]
        case .artist: return [.artistImage]
        case .aiBatch: return [.identified]
        }
    }
}

public struct EnrichmentRecord: Codable, Sendable, Equatable {
    public var scope: EnrichmentScope
    public var key: String
    public var version: Int
    public var status: EnrichmentStatus
    public var fields: EnrichmentFields
    public var attempts: Int
    public var lastAttemptAt: Date?
    public var nextEligibleAt: Date?
    public var lastFailure: EnrichmentFailure?

    public init(
        scope: EnrichmentScope,
        key: String,
        version: Int = 0,
        status: EnrichmentStatus = .pending,
        fields: EnrichmentFields = [],
        attempts: Int = 0,
        lastAttemptAt: Date? = nil,
        nextEligibleAt: Date? = nil,
        lastFailure: EnrichmentFailure? = nil
    ) {
        self.scope = scope
        self.key = key
        self.version = version
        self.status = status
        self.fields = fields
        self.attempts = attempts
        self.lastAttemptAt = lastAttemptAt
        self.nextEligibleAt = nextEligibleAt
        self.lastFailure = lastFailure
    }
}

/// The idempotence predicate. One function; nothing else in either codebase may
/// gate an attempt. Satisfaction is re-derived from `fields` on every read
/// rather than trusted from `status`, so widening `required(for:)` in a future
/// release revives exactly the entities that no longer meet the bar, with no
/// migration.
public enum EnrichmentPolicy {

    /// 1 day, then 7, then 30, then terminal.
    public static let backoff: [TimeInterval] = [86_400, 7 * 86_400, 30 * 86_400]

    /// Consecutive transport outcomes after which a pass stops guessing and
    /// parks until the route genuinely changes. Transport failures write
    /// nothing durable, so parking costs the queue nothing and spares a
    /// captive portal five more round trips per page.
    public static let transportFailuresBeforeWaiting = 5

    public static func isDue(_ record: EnrichmentRecord?, scope: EnrichmentScope, now: Date) -> Bool {
        guard let record else { return true }
        if record.fields.isSuperset(of: EnrichmentFields.required(for: scope)) { return false }
        switch record.status {
        case .satisfied, .pending: return true
        case .exhausted: return record.version < scope.currentVersion
        case .partial:
            return record.version < scope.currentVersion || (record.nextEligibleAt ?? now) <= now
        }
    }

    /// Applies one attempt's outcome. `attempts` and `nextEligibleAt` are left
    /// untouched for failures the sources never actually answered, which is what
    /// makes an entirely offline launch cost zero durable state.
    public static func apply(
        to record: inout EnrichmentRecord,
        scope: EnrichmentScope,
        resolved: EnrichmentFields,
        failure: EnrichmentFailure?,
        now: Date
    ) {
        record.version = scope.currentVersion
        record.fields.formUnion(resolved)
        record.lastFailure = failure

        switch failure {
        case .transport, .unauthorized:
            record.status = record.fields.isSuperset(of: EnrichmentFields.required(for: scope))
                ? .satisfied : .pending
            record.nextEligibleAt = nil
            return
        case .rateLimited:
            record.status = .partial
            record.lastAttemptAt = now
            record.nextEligibleAt = now.addingTimeInterval(15 * 60)
            return
        case .notFound, nil:
            record.attempts += 1
            record.lastAttemptAt = now
        }

        if record.fields.isSuperset(of: EnrichmentFields.required(for: scope)) {
            record.status = .satisfied
            record.nextEligibleAt = nil
        } else if record.attempts >= scope.maxAttempts {
            record.status = .exhausted
            record.nextEligibleAt = nil
        } else {
            record.status = .partial
            record.nextEligibleAt = now.addingTimeInterval(backoff[min(record.attempts - 1, backoff.count - 1)])
        }
    }
}

/// Key normalization, identical in Swift, Rust and the SQL seeds. A mismatch
/// produces a silent full re-enrichment rather than an error, so the
/// cross-language key test is load-bearing.
public enum EnrichmentKey {
    public static func album(title: String, artist: String) -> String {
        normalize(title) + "\u{1F}" + normalize(artist)
    }
    public static func artist(_ name: String) -> String { normalize(name) }
    /// The directory that `Library.analyzeLibrary` batches by: the file's parent
    /// path with no trailing slash, or "" for a track at the library root.
    public static func aiBatch(directory: String) -> String { normalize(directory) }

    /// The name each client registers this normalizer under, so every SQL
    /// statement that derives a key calls the same code the app does. SQLite's
    /// own `lower()` is ASCII-only and its `trim()` strips spaces alone.
    public static let sqlFunctionName = "flaccy_norm"

    public static func normalize(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

/// What the job tells a surface. Deliberately fraction-free: the work is
/// unbounded network work and a percentage over it would be a guess, so clients
/// count down instead of drawing a bar.
public struct EnrichmentJobProgress: Codable, Sendable, Equatable {
    public enum Activity: String, Codable, Sendable {
        case idle, running, waitingForNetwork, needsEntitlement
    }
    public var activity: Activity
    public var scope: EnrichmentScope
    public var remaining: Int
    public var completedThisRun: Int
    public var exhausted: Int
    public var currentTitle: String?
    public var startedAt: Date?

    public init(
        activity: Activity,
        scope: EnrichmentScope,
        remaining: Int,
        completedThisRun: Int,
        exhausted: Int,
        currentTitle: String?,
        startedAt: Date?
    ) {
        self.activity = activity
        self.scope = scope
        self.remaining = remaining
        self.completedThisRun = completedThisRun
        self.exhausted = exhausted
        self.currentTitle = currentTitle
        self.startedAt = startedAt
    }

    public static let idle = EnrichmentJobProgress(
        activity: .idle, scope: .album, remaining: 0,
        completedThisRun: 0, exhausted: 0, currentTitle: nil, startedAt: nil
    )
    public var isActive: Bool { activity != .idle }
}
