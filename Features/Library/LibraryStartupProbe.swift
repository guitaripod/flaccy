import FlaccyCore
import Foundation

/// Whether some earlier launch already built a library, answered without
/// opening the database.
///
/// The Debut has to decide whether it is taking the screen over *before* any
/// disk work starts, and by the time a `SELECT` could answer the question the
/// first frame has already been drawn — which is exactly how the frozen 1% ring
/// got on screen. `IndexedLibraryRecord` answers from a file's existence, which
/// costs nothing and survives a launch that finds the preferences unreadable.
nonisolated enum LibraryStartupProbe {

    private static var record: IndexedLibraryRecord {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("flaccy", isDirectory: true)
        return IndexedLibraryRecord(folder: folder, defaults: .standard)
    }

    static var hadIndexedLibrary: Bool {
        record.hadIndexedLibrary
    }

    /// Called whenever a load yields albums; writes only when the record is missing.
    static func markIndexed() {
        record.markIndexed()
    }

    /// Only "Reset Library" clears this — the Debut is a per-library showpiece,
    /// so a delete-and-reinstall correctly earns it again.
    static func clear() {
        record.clear()
    }
}
