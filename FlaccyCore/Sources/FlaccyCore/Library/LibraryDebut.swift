import Foundation

/// The once-per-library figures the summary card reports. Written exactly once,
/// alongside `libraryDebut.completedAt`, and cleared only by "Reset Library".
public struct LibraryDebutSummary: Codable, Sendable, Equatable {
    public var trackCount: Int
    public var albumCount: Int
    public var artistCount: Int
    public var coversResolved: Int
    public var albumsDated: Int
    public var aiCleanedTracks: Int
    public var losslessTrackCount: Int
    public var averageBitrate: Int
    public var totalDurationSeconds: Double
    public var completedAt: Date

    public init(
        trackCount: Int,
        albumCount: Int,
        artistCount: Int,
        coversResolved: Int,
        albumsDated: Int,
        aiCleanedTracks: Int,
        losslessTrackCount: Int,
        averageBitrate: Int,
        totalDurationSeconds: Double,
        completedAt: Date
    ) {
        self.trackCount = trackCount
        self.albumCount = albumCount
        self.artistCount = artistCount
        self.coversResolved = coversResolved
        self.albumsDated = albumsDated
        self.aiCleanedTracks = aiCleanedTracks
        self.losslessTrackCount = losslessTrackCount
        self.averageBitrate = averageBitrate
        self.totalDurationSeconds = totalDurationSeconds
        self.completedAt = completedAt
    }
}

public enum LibraryDebutAct: Int, Codable, Sendable, Comparable {
    case indexing, finishing, summary, done
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct LibraryDebutDirector: Sendable {

    /// The longest the finishing act may hold a new user's library. Whatever is
    /// still queued after this continues on the ambient surface.
    public static let curtainBudget: TimeInterval = 90

    public private(set) var act: LibraryDebutAct = .indexing

    public init() {}

    /// Advances the act, never backwards. Returns true when the act changed.
    ///
    /// `jobHeardFrom` must be false until the enrichment coordinator has
    /// published at least once this run: the job snapshot starts life `.idle`
    /// with nothing remaining, which reads as drained and would skip the
    /// finishing act entirely. The curtain remains the hard ceiling, so a job
    /// that never reports still cannot hold the debut open.
    @discardableResult
    public mutating func advance(
        load: LibraryLoadProgress,
        job: EnrichmentJobProgress,
        albumCount: Int,
        elapsedInFinishing: TimeInterval,
        jobHeardFrom: Bool = true
    ) -> Bool {
        let next = Self.target(load: load, job: job, albumCount: albumCount,
                               elapsedInFinishing: elapsedInFinishing,
                               jobHeardFrom: jobHeardFrom, current: act)
        guard next > act else { return false }
        act = next
        return true
    }

    private static func target(
        load: LibraryLoadProgress, job: EnrichmentJobProgress, albumCount: Int,
        elapsedInFinishing: TimeInterval, jobHeardFrom: Bool, current: LibraryDebutAct
    ) -> LibraryDebutAct {
        if load.phase.blocksLibrary { return .indexing }
        guard albumCount > 0 else { return .done }
        if current == .indexing { return .finishing }
        if current == .finishing {
            let drained = jobHeardFrom && (job.activity == .idle || job.remaining == 0)
            let curtain = elapsedInFinishing >= curtainBudget
            let blocked = job.activity == .needsEntitlement
            return (drained || curtain || blocked) ? .summary : .finishing
        }
        return current
    }
}
