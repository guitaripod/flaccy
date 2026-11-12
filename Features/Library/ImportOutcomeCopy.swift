import FlaccyCore
import Foundation

/// The one sentence every client shows when an import finishes, built from the
/// same outcome so iOS and macOS never describe the same result differently.
/// Mirrored for Linux by `import_plan::report` in `linux/shared`.
enum ImportOutcomeCopy {

    struct Report {
        let message: String
        let isFailure: Bool
        let isNoOp: Bool
        /// Nothing came in and nothing was already there: the person is left with no music from this pick, so the
        /// client offers the ways music does get in.
        var isDeadEnd = false
    }

    static var scanning: String {
        String(localized: "Looking for music…")
    }

    static func progress(_ progress: LibraryImportProgress) -> String {
        switch progress {
        case .scanning:
            return scanning
        case .copying(let done, let total):
            return String(localized: "Copying \(LibraryLoadPhaseCopy.number(done)) of \(LibraryLoadPhaseCopy.number(total))…")
        }
    }

    static func report(_ outcome: LibraryImportOutcome) -> Report {
        if let shortfall = outcome.shortfall { return shortfallReport(shortfall) }
        let counted = outcome.imported > 0 || outcome.skipped > 0 || outcome.failed > 0
        guard counted || outcome.replaced > 0 || outcome.stopped > 0 else {
            guard outcome.lyrics == 0 else { return lyricsReport(outcome) }
            return passedOverReport(outcome)
        }
        var parts: [String] = []
        var isFailure = false
        var isNoOp = outcome.replaced == 0 && outcome.imported == 0
        if counted {
            let report = outcome.replaced > 0 && outcome.imported == 0 && outcome.failed > 0
                ? Report(message: String(localized: "\(outcome.failed) failed to copy"), isFailure: true, isNoOp: false)
                : countedReport(outcome)
            parts.append(report.message)
            isFailure = report.isFailure
            isNoOp = isNoOp && report.isNoOp
        }
        if outcome.replaced > 0 {
            parts.append(String(localized: "\(outcome.replaced) songs replaced with newer versions"))
        }
        if outcome.stopped > 0 {
            parts.append(stoppedNote(outcome.stopped))
        }
        parts += passedOverNotes(outcome)
        return Report(message: joined(parts), isFailure: isFailure, isNoOp: isNoOp)
    }

    private static func shortfallReport(_ shortfall: StorageShortfall) -> Report {
        let needed = ByteCountFormatter.string(fromByteCount: shortfall.needed, countStyle: .file)
        let available = ByteCountFormatter.string(fromByteCount: shortfall.available, countStyle: .file)
        return Report(
            message: String(localized: "Not enough space — this import needs \(needed), only \(available) is free."),
            isFailure: true, isNoOp: false
        )
    }

    private static func countedReport(_ outcome: LibraryImportOutcome) -> Report {
        switch (outcome.imported, outcome.skipped, outcome.failed) {
        case (0, 0, 0):
            return Report(message: noMusicFound, isFailure: false, isNoOp: true)
        case (0, let skipped, 0):
            return Report(
                message: skipped == 1
                    ? String(localized: "Already in your library.")
                    : String(localized: "All \(skipped) items are already in your library."),
                isFailure: false, isNoOp: true
            )
        case (0, _, _):
            return Report(message: String(localized: "Import failed — the files couldn't be copied."), isFailure: true, isNoOp: false)
        case (let imported, 0, 0):
            return Report(message: String(localized: "Imported \(imported) items"), isFailure: false, isNoOp: false)
        case (let imported, let skipped, 0):
            return Report(message: String(localized: "Imported \(imported), \(skipped) already in your library"), isFailure: false, isNoOp: false)
        case (let imported, _, let failed):
            return Report(message: String(localized: "Imported \(imported), \(failed) failed to copy"), isFailure: true, isNoOp: false)
        }
    }

    /// Nothing but lyrics came in: sidecars for songs already in the library, which is a pick that worked.
    private static func lyricsReport(_ outcome: LibraryImportOutcome) -> Report {
        let added = outcome.lyrics == 1
            ? String(localized: "Added 1 lyrics file")
            : String(localized: "Added \(outcome.lyrics) lyrics files")
        return Report(message: joined([added] + passedOverNotes(outcome)), isFailure: false, isNoOp: false)
    }

    /// The pick held no music this app can take, so the report leads with why: formats it cannot play, music still
    /// inside a zip, or nothing that looks like music at all.
    private static func passedOverReport(_ outcome: LibraryImportOutcome) -> Report {
        let unplayable = outcome.unplayable.values.reduce(0, +)
        var parts: [String] = []
        if unplayable > 0 {
            let formats = formatNames(outcome.unplayable).formatted(.list(type: .or))
            parts.append(unplayable == 1
                ? String(localized: "Flaccy can't play \(formats) files, so this one wasn't added.")
                : String(localized: "Flaccy can't play \(formats) files, so these \(unplayable) weren't added."))
        }
        if outcome.unplayable[ImportPlan.protectedExtension] != nil { parts.append(protectedNote) }
        if outcome.archives > 0 {
            parts.append(unplayable > 0 ? archiveNote(outcome.archives) : archiveLead(outcome.archives))
        }
        if parts.isEmpty { parts.append(noMusicFound) }
        return Report(message: joined(parts), isFailure: false, isNoOp: true, isDeadEnd: true)
    }

    private static func passedOverNotes(_ outcome: LibraryImportOutcome) -> [String] {
        var notes: [String] = []
        let unplayable = outcome.unplayable.values.reduce(0, +)
        if unplayable > 0 {
            let formats = formatNames(outcome.unplayable).formatted(.list(type: .and))
            notes.append(unplayable == 1
                ? String(localized: "1 \(formats) file wasn't added: Flaccy can't play it.")
                : String(localized: "\(unplayable) \(formats) files weren't added: Flaccy can't play them."))
        }
        if outcome.unplayable[ImportPlan.protectedExtension] != nil { notes.append(protectedNote) }
        if outcome.archives > 0 { notes.append(archiveNote(outcome.archives)) }
        return notes
    }

    /// Why protected iTunes Store purchases stay out, after the sentence that counts them.
    private static var protectedNote: String {
        String(localized: "M4P songs are iTunes Store purchases that only Apple's Music app can play.")
    }

    private static var noMusicFound: String {
        String(localized: "No music found there. Flaccy adds FLAC, ALAC, MP3, AAC, WAV and AIFF files.")
    }

    private static func archiveLead(_ count: Int) -> String {
        #if os(macOS)
        count == 1
            ? String(localized: "The music there is in a zip archive. Double-click it in the Finder to unzip it, then add the folder it makes.")
            : String(localized: "The music there is in \(count) zip archives. Double-click each in the Finder to unzip it, then add the folders they make.")
        #else
        count == 1
            ? String(localized: "The music there is in a zip archive. Tap it in the Files app to unzip it, then add the folder it makes.")
            : String(localized: "The music there is in \(count) zip archives. Tap each in the Files app to unzip it, then add the folders they make.")
        #endif
    }

    private static func archiveNote(_ count: Int) -> String {
        count == 1
            ? String(localized: "1 zip archive wasn't opened: unzip it first.")
            : String(localized: "\(count) zip archives weren't opened: unzip them first.")
    }

    private static func stoppedNote(_ count: Int) -> String {
        count == 1
            ? String(localized: "Stopped with 1 song left. Add the same songs again to finish.")
            : String(localized: "Stopped with \(count) songs left. Add the same songs again to finish.")
    }

    /// The extensions as people see them on their files, in a stable order.
    private static func formatNames(_ unplayable: [String: Int]) -> [String] {
        unplayable.keys.sorted().map { $0.uppercased() }
    }

    private static func joined(_ parts: [String]) -> String {
        parts.joined(separator: " · ")
    }
}
