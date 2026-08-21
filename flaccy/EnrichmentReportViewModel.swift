import FlaccyCore
import Foundation

/// One entity the job ran out of attempts on, already worded for display.
nonisolated struct EnrichmentReportEntity: Sendable, Hashable {
    let scope: EnrichmentScope
    let key: String
    let name: String
    let detail: String
}

nonisolated enum EnrichmentReportSection: Int, Hashable, CaseIterable, Sendable {
    case summary, retry, gaveUp
}

/// The rows the report and the Mac's Library pane both render. Deliberately not
/// nested inside the view model: a diffable data source requires a `Sendable`
/// item identifier, and a type nested in a main-actor class carries a
/// main-actor-isolated `Hashable` conformance that cannot satisfy it.
nonisolated enum EnrichmentReportRow: Hashable, Sendable {
    case summary(String)
    case tryAgain(isRetrying: Bool)
    case entity(EnrichmentReportEntity)
}

/// The three counts the report leads with, plus the entities behind the last of
/// them. Read in one hop off the main thread so the table never blocks on
/// SQLite.
nonisolated struct EnrichmentReportCounts: Sendable, Equatable {
    var complete: Int
    var inProgress: Int
    var gaveUp: Int
    var entities: [EnrichmentReportEntity]

    static let empty = EnrichmentReportCounts(complete: 0, inProgress: 0, gaveUp: 0, entities: [])
}

/// What the metadata report knows: how much of the library is settled, how much
/// is still queued, and exactly which albums and artists no source could answer
/// for. Every number is a `count(*)` over the same predicate the queue drains,
/// so the report and the job can never disagree.
///
/// UIKit-free on purpose — the Mac's Library settings pane needs the same three
/// counts and the same Try Again, and a second copy of this arithmetic is
/// exactly the kind of drift the shared model exists to prevent.
@MainActor
final class EnrichmentReportViewModel {

    typealias Section = EnrichmentReportSection
    typealias Row = EnrichmentReportRow

    /// The scopes a person can recognise in a list. `aiBatch` is deliberately
    /// absent: a directory of files is not an entity worth naming, and
    /// `EnrichmentJobCopy.missingMetadata` refuses to word one.
    private static let reportedScopes: [EnrichmentScope] = [.album, .artist]

    /// How long a burst of job publishes has to go quiet before the counts are
    /// re-read.
    private static let jobDebounce: TimeInterval = 0.5

    var onChange: (() -> Void)?

    private(set) var counts = EnrichmentReportCounts.empty
    private(set) var isRetrying = false

    private var refreshTask: Task<Void, Never>?

    var canRetry: Bool { counts.gaveUp > 0 && !isRetrying }

    var sections: [Section] {
        counts.entities.isEmpty ? [.summary, .retry] : Section.allCases
    }

    func rows(in section: Section) -> [Row] {
        switch section {
        case .summary:
            return [.summary(EnrichmentJobCopy.reportCounts(
                complete: counts.complete, inProgress: counts.inProgress, gaveUp: counts.gaveUp
            ))]
        case .retry:
            return [.tryAgain(isRetrying: isRetrying)]
        case .gaveUp:
            return counts.entities.map(Row.entity)
        }
    }

    func footer(for section: Section) -> String? {
        switch section {
        case .summary:
            return EnrichmentJobCopy.settled(remaining: counts.inProgress, gaveUp: counts.gaveUp)
        case .retry:
            return String(localized: "Re-fetch artwork and release dates for albums Flaccy gave up on.")
        case .gaveUp:
            return nil
        }
    }

    func start() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(jobProgressChanged),
            name: EnrichmentCoordinator.progressDidChange, object: nil
        )
        refresh()
    }

    @objc private func jobProgressChanged() {
        refresh(after: Self.jobDebounce)
    }

    /// Re-reads every count off the main thread. A refresh already in flight is
    /// cancelled rather than queued, so a burst of job publishes costs one read
    /// at the end of the burst instead of four a second for the length of a pass
    /// — `exhaustedEntities` is a full table scan and Settings holds one of
    /// these open too.
    func refresh(after delay: TimeInterval = 0) {
        refreshTask?.cancel()
        let names = displayNames()
        let universe = names.albums.count + names.artists.count
        refreshTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
            }
            let next = await Self.read(names: names, universe: universe)
            guard !Task.isCancelled else { return }
            guard let self, next != self.counts else { return }
            self.counts = next
            self.onChange?()
        }
    }

    /// Requeues everything the job gave up on, in every scope the report lists,
    /// and lets the coordinator start a pass. The fields already resolved
    /// survive, so a retry only chases what is still missing.
    func retry() {
        guard canRetry else { return }
        isRetrying = true
        onChange?()
        Task { [weak self] in
            for scope in Self.reportedScopes {
                await EnrichmentCoordinator.shared.retryExhausted(scope: scope)
            }
            guard let self else { return }
            self.isRetrying = false
            self.refresh()
            self.onChange?()
        }
    }

    /// The properly-cased names the database only holds normalized. An
    /// enrichment key is lower-cased and trimmed by design, so it is matched
    /// back against what the library is actually showing rather than printed
    /// raw.
    private struct DisplayNames: Sendable {
        var albums: [String: String]
        var artists: [String: String]
    }

    private func displayNames() -> DisplayNames {
        var albums: [String: String] = [:]
        var artists: [String: String] = [:]
        for album in Library.shared.albums {
            albums[EnrichmentKey.album(title: album.title, artist: album.artist)] =
                "\(album.title) — \(album.artist)"
            artists[EnrichmentKey.artist(album.artist)] = album.artist
        }
        return DisplayNames(albums: albums, artists: artists)
    }

    private nonisolated static func read(names: DisplayNames, universe: Int) async -> EnrichmentReportCounts {
        let db = DatabaseManager.shared
        let now = Date()
        var inProgress = 0
        var gaveUp = 0
        var entities: [EnrichmentReportEntity] = []

        for scope in reportedScopes {
            inProgress += (try? db.countDue(scope: scope, version: scope.currentVersion, now: now)) ?? 0
            let exhausted = (try? db.exhaustedEntities(scope: scope)) ?? []
            gaveUp += exhausted.count
            entities.append(contentsOf: exhausted.compactMap { entity(from: $0, names: names) })
        }

        return EnrichmentReportCounts(
            complete: max(0, universe - inProgress - gaveUp),
            inProgress: inProgress,
            gaveUp: gaveUp,
            entities: entities
        )
    }

    /// A record only reaches `exhausted` through `EnrichmentPolicy.apply`, which
    /// stamps `lastAttemptAt` on the same pass, so a row without a date is a row
    /// there is nothing true to say about.
    private nonisolated static func entity(
        from record: EnrichmentRecord, names: DisplayNames
    ) -> EnrichmentReportEntity? {
        guard let missing = EnrichmentJobCopy.missingMetadata(scope: record.scope, fields: record.fields),
              let lastAttempt = record.lastAttemptAt
        else { return nil }

        let lookup = record.scope == .album ? names.albums : names.artists
        guard let name = lookup[record.key] ?? fallbackName(for: record) else { return nil }

        return EnrichmentReportEntity(
            scope: record.scope,
            key: record.key,
            name: name,
            detail: EnrichmentJobCopy.reportRow(
                missing, attempts: record.attempts, lastAttempt: lastAttempt
            )
        )
    }

    /// An entity the library no longer holds — a rescan mid-report, say — is
    /// still named from its own key rather than dropped, so the row count and
    /// the Gave up total agree.
    private nonisolated static func fallbackName(for record: EnrichmentRecord) -> String? {
        let parts = record.key.split(separator: "\u{1F}", omittingEmptySubsequences: false)
        guard let title = parts.first, !title.isEmpty else { return nil }
        guard parts.count > 1 else { return String(title) }
        return "\(title) — \(parts[1])"
    }

    deinit {
        refreshTask?.cancel()
    }
}
