import Foundation

/// Whether some earlier launch already built a library, recorded in
/// `UserDefaults` rather than derived from the database.
///
/// The Debut has to decide whether it is taking the screen over *before* any
/// disk work starts, and by the time a `SELECT` could answer the question the
/// first frame has already been drawn — which is exactly how the frozen 1% ring
/// got on screen. Reading a plist key costs nothing and is honest at launch.
nonisolated enum LibraryStartupProbe {

    private static let key = "flaccy.library.hadIndexedLibrary"

    static var hadIndexedLibrary: Bool {
        UserDefaults.standard.bool(forKey: key)
    }

    /// Called once the first `loadFromDatabase()` that yielded albums returns.
    static func markIndexed() {
        UserDefaults.standard.set(true, forKey: key)
    }

    /// Only "Reset Library" clears this — the Debut is a per-library showpiece,
    /// so a delete-and-reinstall correctly earns it again.
    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
