import FlaccyServerEmbed
import Foundation

/// Opens the folder the Mac library indexes for the server: the person's chosen folder through its security-scoped bookmark,
/// held until the server has stopped, or the container's own folder when none was chosen.
nonisolated struct LibraryFolderAccess: SharedFolderAccess {

    func open() -> SharedFolder? {
        guard !LibraryRoot.shared.isFallbackActive else { return nil }
        guard let bookmark = UserDefaults.standard.data(forKey: LibraryRoot.bookmarkKey) else {
            return SharedFolder(url: LibraryRoot.current, release: {})
        }
        var isStale = false
        guard let folder = try? URL(
            resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &isStale
        ), folder.startAccessingSecurityScopedResource() else { return nil }
        return SharedFolder(url: folder.standardizedFileURL) { folder.stopAccessingSecurityScopedResource() }
    }
}
