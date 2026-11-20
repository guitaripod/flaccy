import Foundation

/// The clean view of the library: each song once, wherever its copies live (in the library folder, on a server, or
/// tagged with another artist on the same album), and the editions of an album as one album. Nothing is deleted;
/// the copies stay a long press away. Replaces Hide Duplicate Songs and Group Album Editions, whose stored choices
/// decide the first value: clean only when both were on, as they are by default.
nonisolated enum CleanLibrarySetting {
    static let key = "cleanLibrary"
    static let didChange = Notification.Name("CleanLibraryDidChange")
    private static let legacyHideDuplicatesKey = "hideDuplicateSongs"
    private static let legacyGroupEditionsKey = "groupAlbumEditions"

    static var isEnabled: Bool {
        let defaults = UserDefaults.standard
        if let chosen = defaults.object(forKey: key) as? Bool { return chosen }
        let hidesDuplicates = defaults.object(forKey: legacyHideDuplicatesKey) as? Bool ?? true
        let groupsEditions = defaults.object(forKey: legacyGroupEditionsKey) as? Bool ?? true
        return hidesDuplicates && groupsEditions
    }

    /// Stores the choice and rebuilds the library, since the editions of an album are folded as it loads.
    @MainActor
    static func set(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: key)
        NotificationCenter.default.post(name: didChange, object: nil)
        Task { await Library.shared.reloadFromDatabase() }
    }

    /// An album as Clean Library shows it: each of its songs once, keeping the loved copy, then the best one, in album
    /// order. An album whose songs are on this device and on a server lists each song once instead of twice.
    static func eachSongOnce(in album: Album) -> Album {
        guard isEnabled, album.tracks.count > 1 else { return album }
        let kept = LibraryHygiene.collapsingDuplicateSongs(album.tracks) { LovedTracksService.shared.isLoved(track: $0) ? 1 : 0 }.tracks
        guard kept.count < album.tracks.count else { return album }
        return Album(title: album.title, artist: album.artist, artwork: album.artwork, tracks: kept, year: album.year, genre: album.genre)
    }

    /// A pool for stations and suggestions with each song once, so a queue
    /// built from it never plays the same recording twice. Tracks in
    /// `preferring` always survive as the copy of their song, which lets the
    /// caller then exclude them without a hidden twin slipping back in.
    static func uniquePool(_ pool: [Track], preferring preferred: [Track] = []) -> [Track] {
        guard isEnabled else { return pool }
        let preferredURLs = Set(preferred.map(\.fileURL))
        return LibraryHygiene.collapsingDuplicateSongs(pool) { preferredURLs.contains($0.fileURL) ? 1 : 0 }.tracks
    }
}
