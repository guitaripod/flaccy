import Foundation

/// The stage a library load is in, in the order the clients perform them.
/// Shared so iOS, macOS and watchOS describe a scan with the same vocabulary.
public enum LibraryLoadPhase: Int, Sendable, CaseIterable, Comparable {
    case idle
    case openingLibrary
    case findingFiles
    case readingTags
    case identifyingMusic
    case buildingAlbums
    case enrichingArtwork

    public static func < (lhs: LibraryLoadPhase, rhs: LibraryLoadPhase) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Share of a whole first load this phase accounts for, tuned so the bar
    /// moves at a roughly steady rate on a real library instead of sitting at
    /// zero through the tag read and then jumping.
    public var weight: Double {
        switch self {
        case .idle: return 0
        case .openingLibrary: return 0.02
        case .findingFiles: return 0.13
        case .readingTags: return 0.45
        case .identifyingMusic: return 0.15
        case .buildingAlbums: return 0.05
        case .enrichingArtwork: return 0.20
        }
    }

    /// Cumulative weight of every phase before this one.
    public var start: Double {
        LibraryLoadPhase.allCases
            .filter { $0.rawValue < rawValue }
            .reduce(0) { $0 + $1.weight }
    }

    /// Phases whose work the user is waiting on before any library can appear.
    /// Artwork enrichment continues behind an already-usable library.
    public var blocksLibrary: Bool {
        self > .idle && self < .enrichingArtwork
    }
}

/// A snapshot of an in-flight library load: which stage it is in, how far
/// through that stage it is, and the running tallies worth showing a person
/// who is watching an empty screen.
public struct LibraryLoadProgress: Sendable, Equatable {

    public var phase: LibraryLoadPhase
    public var completed: Int
    public var total: Int
    public var filesFound: Int
    public var tracksIndexed: Int
    public var albumsBuilt: Int

    public init(
        phase: LibraryLoadPhase = .idle,
        completed: Int = 0,
        total: Int = 0,
        filesFound: Int = 0,
        tracksIndexed: Int = 0,
        albumsBuilt: Int = 0
    ) {
        self.phase = phase
        self.completed = completed
        self.total = total
        self.filesFound = filesFound
        self.tracksIndexed = tracksIndexed
        self.albumsBuilt = albumsBuilt
    }

    public static let idle = LibraryLoadProgress()

    public var isActive: Bool { phase != .idle }

    /// True when the phase reports a countable unit of work, so the client can
    /// show a real bar instead of an indeterminate one.
    public var isDeterminate: Bool { total > 0 }

    /// How far through the current phase, 0…1.
    public var phaseFraction: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(completed) / Double(total)))
    }

    /// How far through the whole load, 0…1, weighting each phase by how long it
    /// typically takes. Indeterminate phases count as half done so the bar
    /// still advances when a phase starts.
    public var fractionCompleted: Double {
        guard phase != .idle else { return 0 }
        let within = isDeterminate ? phaseFraction : 0.5
        return min(1, phase.start + phase.weight * within)
    }
}

/// Coalesces raw progress updates from a scan into a stream a UI can bind to:
/// the reported fraction never moves backwards, and updates that would not
/// visibly change anything are dropped instead of waking the main thread.
public final class LibraryLoadProgressTracker: @unchecked Sendable {

    /// Smallest fraction change worth a UI update; a 5000-track scan otherwise
    /// posts thousands of notifications nobody can perceive.
    private static let fractionEpsilon = 0.004

    private let lock = NSLock()
    private let minimumInterval: TimeInterval
    private var current = LibraryLoadProgress.idle
    private var highWaterFraction: Double = 0
    private var lastPublishedFraction: Double = 0
    private var lastPublishedAt: TimeInterval = 0

    /// - Parameter minimumInterval: how often a counter-only change (files
    ///   found during an indeterminate sweep) may reach the UI.
    public init(minimumInterval: TimeInterval = 0.1) {
        self.minimumInterval = minimumInterval
    }

    public var progress: LibraryLoadProgress {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    /// The fraction to show, held at its high-water mark so a phase that
    /// discovers more work never yanks the bar backwards.
    public var displayFraction: Double {
        lock.lock()
        defer { lock.unlock() }
        return highWaterFraction
    }

    /// Applies `mutate` and returns the new progress when the change is worth
    /// publishing, or nil when it is not.
    @discardableResult
    public func update(force: Bool = false, _ mutate: (inout LibraryLoadProgress) -> Void) -> LibraryLoadProgress? {
        lock.lock()
        let previous = current
        var next = current
        mutate(&next)
        current = next
        highWaterFraction = max(highWaterFraction, next.fractionCompleted)
        let now = Date().timeIntervalSinceReferenceDate
        let fractionMoved = abs(highWaterFraction - lastPublishedFraction) >= Self.fractionEpsilon
        let structuralChange = next.phase != previous.phase || next.total != previous.total
        let countersTicked = next != previous && now - lastPublishedAt >= minimumInterval
        let shouldPublish = force || structuralChange || fractionMoved || countersTicked
        if shouldPublish {
            lastPublishedFraction = highWaterFraction
            lastPublishedAt = now
        }
        lock.unlock()
        return shouldPublish ? next : nil
    }

    /// Ends the load and resets the high-water mark for the next one.
    @discardableResult
    public func finish() -> LibraryLoadProgress {
        lock.lock()
        defer { lock.unlock() }
        current = .idle
        highWaterFraction = 0
        lastPublishedFraction = 0
        lastPublishedAt = 0
        return current
    }
}
