import Foundation

/// Whether some earlier launch already built a library, kept as an empty file
/// beside the database instead of in `UserDefaults` alone.
///
/// A launch can find the preferences unreadable: iOS starts the process before
/// the first unlock after a restart, or prewarms it, and the domain comes back
/// empty for the life of that process. Every key then reads its default, and a
/// person with years of music was shown the first-run Debut over their library.
/// A file's existence is answered by its metadata, which data protection does
/// not lock, so the record holds through those launches. The old preference is
/// still read, so a library indexed before the file existed counts too.
public struct IndexedLibraryRecord {

    public static let legacyDefaultsKey = "flaccy.library.hadIndexedLibrary"
    public static let markerName = ".indexed-library"

    private let marker: URL
    private let defaults: UserDefaults

    public init(folder: URL, defaults: UserDefaults) {
        self.marker = folder.appendingPathComponent(Self.markerName, isDirectory: false)
        self.defaults = defaults
    }

    public var hadIndexedLibrary: Bool {
        FileManager.default.fileExists(atPath: marker.path) || defaults.bool(forKey: Self.legacyDefaultsKey)
    }

    /// Writes the file when it is missing, and nothing else: a preference
    /// written into a domain that read back empty could replace the person's
    /// real settings with it.
    public func markIndexed() {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: marker.path) else { return }
        try? fileManager.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = fileManager.createFile(atPath: marker.path, contents: Data())
    }

    /// Forgets both the file and the old preference, so the next launch earns
    /// the Debut again.
    public func clear() {
        try? FileManager.default.removeItem(at: marker)
        defaults.removeObject(forKey: Self.legacyDefaultsKey)
    }
}
