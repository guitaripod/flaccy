import AppKit

extension Notification.Name {
    static let flaccyRevealAlbum = Notification.Name("flaccy.mac.revealAlbum")
    static let flaccyRevealArtist = Notification.Name("flaccy.mac.revealArtist")
    static let flaccySearchQueryChanged = Notification.Name("flaccy.mac.searchQueryChanged")
}

/// Notification-based navigation to detail surfaces so any component — menus,
/// the transport bar, detail cross-links — can reveal an album or artist
/// without holding a reference to the content router.
enum LibraryNavigator {

    enum Key {
        static let albumTitle = "albumTitle"
        static let artist = "artist"
        static let query = "query"
    }

    static func revealAlbum(title: String, artist: String) {
        NotificationCenter.default.post(
            name: .flaccyRevealAlbum,
            object: nil,
            userInfo: [Key.albumTitle: title, Key.artist: artist]
        )
    }

    static func revealArtist(_ name: String) {
        NotificationCenter.default.post(
            name: .flaccyRevealArtist,
            object: nil,
            userInfo: [Key.artist: name]
        )
    }
}

/// The single source of truth for the toolbar search query, broadcast to the
/// visible section so switching sections keeps the filter consistent.
enum LibrarySearchState {

    private(set) static var query = ""

    static func update(_ newQuery: String) {
        guard query != newQuery else { return }
        query = newQuery
        NotificationCenter.default.post(
            name: .flaccySearchQueryChanged,
            object: nil,
            userInfo: [LibraryNavigator.Key.query: newQuery]
        )
    }
}

nonisolated enum LibraryPathResolver {

    /// The library-root-relative path used as the track's identity in the
    /// database (playlists, loved state, playback restore all key on it).
    static func relativePath(for url: URL) -> String {
        let rootPath = LibraryPaths.root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else { return canonicalSyncPath(url.lastPathComponent) }
        let relative = String(path.dropFirst(rootPath.count))
        return canonicalSyncPath(relative.hasPrefix("/") ? String(relative.dropFirst()) : relative)
    }
}

enum PlaybackFormat {

    static func duration(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded())
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    static func songsAndMinutes(count: Int, totalSeconds: TimeInterval) -> String {
        let minutes = Int((totalSeconds / 60).rounded())
        let songs = count == 1 ? "1 song" : "\(count) songs"
        let time = minutes == 1 ? "1 minute" : "\(minutes) minutes"
        return "\(songs) · \(time)"
    }
}
