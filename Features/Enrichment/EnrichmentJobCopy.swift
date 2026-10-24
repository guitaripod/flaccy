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

    static var dailyLimit: String {
        String(localized: "Daily AI limit reached")
    }

    static var serviceUnavailable: String {
        String(localized: "AI is unavailable right now")
    }

    /// The clock time the daily allowance comes back, in the reader's own format.
    static func resumes(at date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        return String(localized: "Resumes at \(time)")
    }

    /// Two-slot surfaces — a headline and a detail — say why the job is stopped
    /// in the same two slots whatever the reason. Only the stopped activities
    /// have anything to say; the rest answer with nothing. A daily-limit snapshot
    /// that somehow lacks its resume moment still gets the true answer, the
    /// proxy's next UTC midnight, rather than a blank.
    struct Pause: Equatable {
        let headline: String
        let detail: String
    }

    static func pause(for progress: EnrichmentJobProgress) -> Pause {
        switch progress.activity {
        case .waitingForNetwork:
            return Pause(headline: waitingForNetwork, detail: "")
        case .dailyLimit:
            let resumesAt = progress.resumesAt ?? EnrichmentPolicy.nextQuotaReset(after: Date())
            return Pause(headline: dailyLimit, detail: resumes(at: resumesAt))
        case .serviceUnavailable:
            return Pause(headline: serviceUnavailable, detail: "")
        case .idle, .running, .needsEntitlement:
            return Pause(headline: "", detail: "")
        }
    }

    /// The single line an ambient surface shows: the headline and the countdown,
    /// or the state that has replaced them both. An idle job says nothing at all
    /// — a surface with no line is the point of the whole design.
    static func line(for progress: EnrichmentJobProgress) -> String {
        switch progress.activity {
        case .idle:
            return ""
        case .waitingForNetwork, .serviceUnavailable:
            return pause(for: progress).headline
        case .dailyLimit:
            let stopped = pause(for: progress)
            return String(localized: "\(stopped.headline) · \(stopped.detail)")
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
    /// as a sentence. A stopped job names why it stopped rather than counting,
    /// because the count is not what changed.
    static func accessibilityValue(for progress: EnrichmentJobProgress) -> String {
        let headline = headline(for: progress.scope)
        switch progress.activity {
        case .waitingForNetwork:
            return String(localized: "\(headline), waiting for a connection")
        case .dailyLimit:
            let time = (progress.resumesAt ?? EnrichmentPolicy.nextQuotaReset(after: Date()))
                .formatted(date: .omitted, time: .shortened)
            return String(localized: "\(headline), daily AI limit reached, resumes at \(time)")
        case .serviceUnavailable:
            return String(localized: "\(headline), AI is unavailable right now")
        case .idle, .running, .needsEntitlement:
            let count = LibraryLoadPhaseCopy.number(progress.remaining)
            return String(localized: "\(headline), \(count) albums left")
        }
    }
}
