import FlaccyCore
import Foundation

/// The words every client puts on a library load: one headline per phase and a
/// detail line built from the live tallies, so a scan reads the same on iPhone,
/// on the Mac and on the wrist. Every phase here is bounded disk work, so the
/// fraction these words sit next to is one the bar can honestly finish.
nonisolated enum LibraryLoadPhaseCopy {

    static func headline(for phase: LibraryLoadPhase) -> String {
        switch phase {
        case .idle: return String(localized: "Ready")
        case .openingLibrary: return String(localized: "Opening your library")
        case .findingFiles: return String(localized: "Looking for music")
        case .readingTags: return String(localized: "Reading every file")
        case .buildingAlbums: return String(localized: "Building your shelves")
        }
    }

    /// A one-line explanation of what the phase is actually doing, shown while
    /// the library is still empty and there is nothing else on screen.
    static func explanation(for phase: LibraryLoadPhase) -> String {
        switch phase {
        case .idle:
            return ""
        case .openingLibrary:
            return String(localized: "Reading what you already have.")
        case .findingFiles:
            return String(localized: "Nothing is copied or moved — Flaccy reads your files where they are.")
        case .readingTags:
            return String(localized: "Titles, artists, and the exact bit depth and sample rate of every track.")
        case .buildingAlbums:
            return String(localized: "Grouping tracks into albums and artists.")
        }
    }

    /// The counter under the headline: the unit that phase measures, or the
    /// most useful running tally when it has nothing to count.
    static func detail(for progress: LibraryLoadProgress) -> String {
        switch progress.phase {
        case .idle:
            return ""
        case .openingLibrary:
            return progress.tracksIndexed > 0
                ? countLine(progress.tracksIndexed, unit: .tracks)
                : ""
        case .findingFiles:
            return progress.filesFound > 0
                ? countLine(progress.filesFound, unit: .files)
                : String(localized: "Searching…")
        case .readingTags:
            guard progress.total > 0 else { return countLine(progress.tracksIndexed, unit: .tracks) }
            return ofLine(progress.completed, progress.total, unit: .files)
        case .buildingAlbums:
            return progress.tracksIndexed > 0
                ? countLine(progress.tracksIndexed, unit: .tracks)
                : ""
        }
    }

    private enum Unit {
        case files, tracks, albums, folders
    }

    private static func countLine(_ count: Int, unit: Unit) -> String {
        let value = number(count)
        switch unit {
        case .files:
            return count == 1
                ? String(localized: "1 file found")
                : String(localized: "\(value) files found")
        case .tracks:
            return count == 1
                ? String(localized: "1 track")
                : String(localized: "\(value) tracks")
        case .albums:
            return count == 1
                ? String(localized: "1 album")
                : String(localized: "\(value) albums")
        case .folders:
            return count == 1
                ? String(localized: "1 folder")
                : String(localized: "\(value) folders")
        }
    }

    private static func ofLine(_ completed: Int, _ total: Int, unit: Unit) -> String {
        let done = number(min(completed, total))
        let all = number(total)
        switch unit {
        case .files: return String(localized: "\(done) of \(all) files")
        case .tracks: return String(localized: "\(done) of \(all) tracks")
        case .albums: return String(localized: "\(done) of \(all) albums")
        case .folders: return String(localized: "\(done) of \(all) folders")
        }
    }

    static func number(_ value: Int) -> String {
        Self.formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// A day and a month, in the reader's own order — the granularity every
    /// enrichment date is quoted at, shared so the report and the Debut's
    /// settings line can never disagree about how a date looks.
    static func day(_ date: Date) -> String {
        Self.dayFormatter.string(from: date)
    }

    private static let formatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("dMMM")
        return formatter
    }()

    /// Spoken form for assistive technologies: phase, percentage, and counts in
    /// one sentence rather than three separate labels.
    static func accessibilityValue(for progress: LibraryLoadProgress, fraction: Double) -> String {
        let percent = Int((fraction * 100).rounded())
        let detail = detail(for: progress)
        let headline = headline(for: progress.phase)
        guard !detail.isEmpty else { return String(localized: "\(headline), \(percent) percent") }
        return String(localized: "\(headline), \(percent) percent, \(detail)")
    }
}
