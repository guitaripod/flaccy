#if !LEGACY_MAC_HANDOFF
import FlaccyCore
import Foundation
import MidgarCore
import SQLite3

/// First launch of the universal Mac app: when it has no database yet and the old Mac app left an export in the app
/// group, the library comes across, the exported defaults are applied, and the music folder is asked for once more.
/// Runs before anything opens the database or reads the defaults. The export stays where it is, since the old app may
/// still run and write a newer one. An import that failed leaves no completion marker and the app then opens an
/// empty library, so a later launch that finds the export, no marker and zero tracks imports again.
nonisolated enum UniversalMacHandoff {

    static func importIfNeeded() {
        guard let container = HandoffContainer.url else {
            MidgarLog.info("Handoff: no app group container, nothing to import", category: .general)
            return
        }
        do {
            switch try LibraryHandoff.importExport(
                from: container, into: dataFolder, libraryIsEmpty: { !libraryHasTracks(at: $0) }
            ) {
            case .noExport:
                MidgarLog.info("Handoff: no export from the old Mac app", category: .general)
            case .databaseExists:
                MidgarLog.info("Handoff: this app already has a library, the export is left alone", category: .general)
            case .imported(let manifest, let defaults):
                apply(defaults)
                if let path = manifest.libraryFolderPath {
                    HandoffFolderPrompt.markPending(path: path)
                }
                MidgarLog.info(
                    "Handoff: imported the library of the old Mac app \(manifest.appVersion) exported at \(manifest.exportedAt), folder \(manifest.libraryFolderPath ?? "none")",
                    category: .general
                )
            }
        } catch {
            MidgarLog.error("Handoff: import failed: \(error.localizedDescription)", category: .general)
        }
    }

    static var dataFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("flaccy", isDirectory: true)
    }

    /// Read-only, so a library that cannot be read counts as having none and an unreadable file is never modified.
    private static func libraryHasTracks(at database: URL) -> Bool {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(database.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return false
        }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT EXISTS(SELECT 1 FROM tracks)", -1, &statement, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_int(statement, 0) == 1
    }

    /// The folder bookmark is the one default that cannot travel: it is scoped to the old app.
    private static func apply(_ defaults: [String: Any]) {
        for (key, value) in defaults where key != LibraryRoot.bookmarkKey {
            UserDefaults.standard.set(value, forKey: key)
        }
    }
}
#endif
