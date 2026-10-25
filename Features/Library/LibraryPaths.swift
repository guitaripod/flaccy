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
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].standardizedFileURL
        #endif
    }

    /// The slash-separated path of `url` under the root, the key a track is
    /// stored and synced under, in the Unicode form the watch sync uses on the Mac.
    static func relativePath(of url: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        var relative = url.lastPathComponent
        if filePath.hasPrefix(rootPath) {
            relative = String(filePath.dropFirst(rootPath.count))
            if relative.hasPrefix("/") {
                relative = String(relative.dropFirst())
            }
        }
        #if os(macOS)
        return canonicalSyncPath(relative)
        #else
        return relative
        #endif
    }
}
