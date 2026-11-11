import FlaccyCore
import Foundation

/// The single root every shared component resolves track paths against.
/// On iOS this is the app's Documents sandbox, byte-identical to the URLs the
/// shipping code previously derived inline; on macOS it is the user-chosen
/// (or default container) library folder managed by `LibraryRoot`.
nonisolated enum LibraryPaths {

    static var root: URL {
        #if os(macOS)
        LibraryRoot.current
        #else
        documentsRoot
        #endif
    }

    #if !os(macOS)
    /// The Documents folder, looked up once: it cannot move while the app
    /// runs, and every row of every library load asks for it through
    /// `Track.from`, where asking `FileManager` each time cost a launch seconds.
    private static let documentsRoot =
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].standardizedFileURL
    #endif

    /// The root as a plain path. `URL.path` is string work; `standardizedFileURL`
    /// is not — it asks the file system about every component, and a library on
    /// an exFAT card made that a stat per lookup.
    static var rootPath: String { root.path }

    /// The slash-separated path of `url` under the root, the key a track is
    /// stored and synced under, in the Unicode form the watch sync uses on the Mac.
    static func relativePath(of url: URL) -> String {
        if let song = RemoteTrackPath(assetURL: url) { return song.path }
        if let relative = relativePath(of: url, under: rootPath) { return finish(relative) }
        return finish(standardizedRelativePath(of: url))
    }

    /// The relative path when `url` is already the form the library builds
    /// (`root.appendingPathComponent(storedPath)`), without asking the file
    /// system anything; nil when it is not, so the caller can standardize once.
    static func relativePath(of url: URL, under rootPath: String) -> String? {
        let path = url.path
        guard path.hasPrefix(rootPath) else { return nil }
        let relative = String(path.dropFirst(rootPath.count))
        return relative.hasPrefix("/") ? String(relative.dropFirst()) : relative
    }

    private static func standardizedRelativePath(of url: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath) else { return url.lastPathComponent }
        let relative = String(filePath.dropFirst(rootPath.count))
        return relative.hasPrefix("/") ? String(relative.dropFirst()) : relative
    }

    private static func finish(_ relative: String) -> String {
        #if os(macOS)
        return canonicalSyncPath(relative)
        #else
        return relative
        #endif
    }
}
