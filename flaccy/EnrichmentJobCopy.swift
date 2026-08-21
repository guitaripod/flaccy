import FlaccyCore
import Foundation

/// The words every client puts on the enrichment job. The job is deliberately
/// fraction-free, so nothing here ever produces a percentage: a headline names
/// what is being fetched, the detail counts down, and the settled sentences say
/// what the database is left holding.
nonisolated enum EnrichmentJobCopy {

    static func headline(for scope: EnrichmentScope) -> String {
        switch scope {
        case .album: return String(localized: "Finding artwork")
        case .artist: return String(localized: "Finding artists")
        case .aiBatch: return String(localized: "Identifying albums")
        }
    }

    /// The countdown. `remaining` is a count of rows the queue still matches,
    /// never a share of a whole, so it is quoted as work left rather than work
    /// done.
    static func detail(remaining: Int) -> String {
        remaining == 1
            ? String(localized: "1 left")
            : String(localized: "\(LibraryLoadPhaseCopy.number(remaining)) left")
    }

    static var waitingForNetwork: String {
        String(localized: "Waiting for a connection")
    }

    static var needsEntitlement: String {
        String(localized: "AI cleanup needs Flaccy Lifetime")
    }

    /// The single line an ambient surface shows: the headline and the countdown,
    /// or the state that has replaced them both. An idle job says nothing at all
    /// — a surface with no line is the point of the whole design.
    static func line(for progress: EnrichmentJobProgress) -> String {
        switch progress.activity {
        case .idle:
            return ""
        case .waitingForNetwork:
            return waitingForNetwork
        case .needsEntitlement:
            return needsEntitlement
        case .running:
            let headline = headline(for: progress.scope)
            let detail = detail(remaining: progress.remaining)
            return String(localized: "\(headline) · \(detail)")
        }
    }

    /// What Settings and the report say once the job is asleep, in the order the
    /// reader can act on: what is still queued, then what was given up on, then
    /// the all-clear.
    static func settled(remaining: Int, gaveUp: Int) -> String {
        if remaining > 0 {
            let count = LibraryLoadPhaseCopy.number(remaining)
            return String(localized: "\(count) albums are still missing artwork.")
        }
        if gaveUp > 0 {
            let count = LibraryLoadPhaseCopy.number(gaveUp)
            return String(localized: "Flaccy gave up on \(count) albums — no source has them.")
        }
        return String(localized: "Up to date — every album has artwork and a year.")
    }

    static func reportCounts(complete: Int, inProgress: Int, gaveUp: Int) -> String {
        let done = LibraryLoadPhaseCopy.number(complete)
        let queued = LibraryLoadPhaseCopy.number(inProgress)
        let terminal = LibraryLoadPhaseCopy.number(gaveUp)
        return String(localized: "Complete \(done) · In progress \(queued) · Gave up \(terminal)")
    }

    enum MissingMetadata {
        case cover, releaseDate, artistPhoto
    }

    /// Which absence to name for an entity that ran out of attempts: the first
    /// field `EnrichmentFields.required(for:)` still wants. AI batches never
    /// reach the report — a directory of files is not an entity a reader can
    /// recognise — so they name nothing.
    static func missingMetadata(scope: EnrichmentScope, fields: EnrichmentFields) -> MissingMetadata? {
        switch scope {
        case .album: return fields.contains(.cover) ? .releaseDate : .cover
        case .artist: return .artistPhoto
        case .aiBatch: return nil
        }
    }

    /// One report row. `lastAttempt` is not optional because a row only reaches
    /// the report after `EnrichmentPolicy.apply` stamped an attempt on it.
    static func reportRow(_ missing: MissingMetadata, attempts: Int, lastAttempt: Date) -> String {
        let tries = LibraryLoadPhaseCopy.number(attempts)
        let day = LibraryLoadPhaseCopy.day(lastAttempt)
        switch missing {
        case .cover: return String(localized: "No cover found · \(tries) tries · \(day)")
        case .releaseDate: return String(localized: "No release date found · \(tries) tries · \(day)")
        case .artistPhoto: return String(localized: "No artist photo found · \(tries) tries · \(day)")
        }
    }

    static var findMissingArtwork: String {
        String(localized: "Find Missing Artwork")
    }

    static var tryAgain: String {
        String(localized: "Try Again")
    }

    static var openLibrarySettings: String {
        String(localized: "Open Library Settings")
    }

    /// Spoken form for assistive technologies: the same two facts as the line,
    /// as a sentence. Offline is named rather than counted, because the count is
    /// not what changed.
    static func accessibilityValue(for progress: EnrichmentJobProgress) -> String {
        let headline = headline(for: progress.scope)
        guard progress.activity != .waitingForNetwork else {
            return String(localized: "\(headline), waiting for a connection")
        }
        let count = LibraryLoadPhaseCopy.number(progress.remaining)
        return String(localized: "\(headline), \(count) albums left")
    }
}
