import Foundation

/// Which piece of launch chrome, if any, a client should be showing. Clients may
/// only render what the router asks for; there is deliberately no
/// `showsFullScreen` / `showsBanner` pair left to re-derive it from.
public enum LibrarySurface: Int, Sendable, Equatable, Codable {
    case none, ambient, debut
}

public struct LibrarySurfaceRouter: Sendable, Equatable {

    /// How long a background job must be visibly working before it earns an
    /// ambient line, so a relaunch that finds nothing due never flashes one.
    public static let ambientGrace: TimeInterval = 0.25

    private var debutLatched = false

    public init() {}

    public mutating func route(
        load: LibraryLoadProgress,
        job: EnrichmentJobProgress,
        debutCompleted: Bool,
        hasLibrary: Bool,
        elapsed: TimeInterval
    ) -> LibrarySurface {
        if !debutCompleted && !hasLibrary && (load.phase.blocksLibrary || debutLatched) {
            debutLatched = true
            return .debut
        }
        if debutLatched && !debutCompleted { return .debut }
        if load.isActive && hasLibrary { return .ambient }
        if job.activity == .running || job.activity == .waitingForNetwork {
            guard job.completedThisRun >= 1, elapsed >= Self.ambientGrace else { return .none }
            return .ambient
        }
        return .none
    }

    /// Called once the summary card is dismissed (or the build produced no
    /// albums); the debut can never be re-entered for this launch.
    public mutating func releaseDebut() { debutLatched = false }
}
