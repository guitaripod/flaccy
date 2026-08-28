import Foundation

/// The one sentence every client shows when an import finishes, built from the
/// same outcome so iOS and macOS never describe the same result differently.
enum ImportOutcomeCopy {

    struct Report {
        let message: String
        let isFailure: Bool
        let isNoOp: Bool
    }

    static func importing(count: Int) -> String {
        String(localized: "Importing \(count) items…")
    }

    static func report(_ outcome: LibraryImportOutcome) -> Report {
        switch (outcome.imported, outcome.skipped, outcome.failed) {
        case (0, 0, 0):
            return Report(message: String(localized: "Nothing to import."), isFailure: false, isNoOp: true)
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
}
