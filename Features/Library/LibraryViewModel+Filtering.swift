import Combine
import MidgarCore
import FlaccyCore

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

extension LibraryViewModel {

    func filteredAlbums(_ albums: [Album]) -> [Album] {
        switch filter {
        case .all:
            return albums
        case .lossless:
            return albums.filter { representativeTrack(for: $0)?.isLossless == true }
        case .favorites:
            return albums.filter { isLovedAlbum($0) }
        case .recentlyAdded:
            let added = albumDateAddedMap()
            let cutoff = Date().addingTimeInterval(-recentlyWindow)
            let sorted = albums.sorted { (added["\($0.title)|\($0.artist)"] ?? .distantPast) > (added["\($1.title)|\($1.artist)"] ?? .distantPast) }
            let recent = sorted.filter { (added["\($0.title)|\($0.artist)"] ?? .distantPast) >= cutoff }
            return recent.count >= 6 ? recent : Array(sorted.prefix(24))
        case .recentlyPlayed:
            let played = albumLastPlayedMap()
            let cutoff = Date().addingTimeInterval(-recentlyWindow)
            let sorted = albums.filter { played["\($0.title)|\($0.artist)"] != nil }
                .sorted { (played["\($0.title)|\($0.artist)"] ?? .distantPast) > (played["\($1.title)|\($1.artist)"] ?? .distantPast) }
            let recent = sorted.filter { (played["\($0.title)|\($0.artist)"] ?? .distantPast) >= cutoff }
            return recent.count >= 6 ? recent : sorted
        case .rediscover:
            return rediscover.albums
        }
    }

    func filteredSongs(_ songs: [Track]) -> [Track] {
        switch filter {
        case .all:
            return songs
        case .lossless:
            return songs.filter { $0.isLossless }
        case .favorites:
            return songs.filter { LovedTracksService.shared.isLoved(track: $0) }
        case .recentlyAdded:
            let cutoff = Date().addingTimeInterval(-recentlyWindow)
            let sorted = songs.sorted { (meta(for: $0)?.dateAdded ?? .distantPast) > (meta(for: $1)?.dateAdded ?? .distantPast) }
            let recent = sorted.filter { (meta(for: $0)?.dateAdded ?? .distantPast) >= cutoff }
            return recent.count >= 10 ? recent : Array(sorted.prefix(40))
        case .recentlyPlayed:
            let cutoff = Date().addingTimeInterval(-recentlyWindow)
            let sorted = songs.filter { meta(for: $0)?.lastPlayed != nil }
                .sorted { (meta(for: $0)?.lastPlayed ?? .distantPast) > (meta(for: $1)?.lastPlayed ?? .distantPast) }
            let recent = sorted.filter { (meta(for: $0)?.lastPlayed ?? .distantPast) >= cutoff }
            return recent.count >= 10 ? recent : sorted
        case .rediscover:
            let keys = rediscover.keys
            return songs.filter { keys.contains("\($0.albumTitle)|\($0.artist)") }
        }
    }

    /// The alphabet scrubber only makes sense when the visible order is
    /// alphabetical; for time- or count-based sorts the first letters land in
    /// arbitrary order and the index is noise.
    var isCurrentSortAlphabetical: Bool {
        switch currentSegment {
        case .albums: albumSort == .title || albumSort == .artist
        case .songs: songSort == .title || songSort == .artist
        case .artists: artistSort == .name
        case .playlists: false
        }
    }

    func indexTitles() -> [String] {
        let items: [String]
        switch currentSegment {
        case .albums:
            items = sortedAlbums.map { albumSort == .artist ? $0.artist : $0.title }
        case .songs:
            items = sortedSongs.map { songSort == .artist ? $0.artist : $0.title }
        case .artists:
            items = sortedArtists.map(\.name)
        case .playlists:
            return []
        }
        var seen = Set<String>()
        var titles = [String]()
        for item in items {
            let letter = String(item.prefix(1)).uppercased()
            let key = letter.first?.isLetter == true ? letter : "#"
            if seen.insert(key).inserted {
                titles.append(key)
            }
        }
        return titles
    }

    func indexOfFirstItem(forLetter letter: String) -> Int? {
        let items: [(String, Int)]
        switch currentSegment {
        case .albums:
            items = sortedAlbums.enumerated().map { (albumSort == .artist ? $1.artist : $1.title, $0) }
        case .songs:
            items = sortedSongs.enumerated().map { (songSort == .artist ? $1.artist : $1.title, $0) }
        case .artists:
            items = sortedArtists.enumerated().map { ($1.name, $0) }
        case .playlists:
            return nil
        }
        for (name, index) in items {
            let first = String(name.prefix(1)).uppercased()
            let key = first.first?.isLetter == true ? first : "#"
            if key == letter { return index }
        }
        return nil
    }

    /// An artist's albums, split into the ones credited to them and the ones
    /// they merely play on.
    ///
    /// A composer on a Various Artists soundtrack is credited with no album at
    /// all, so a page built from credits alone would be an empty page above a
    /// library holding thirty-one of their tracks. Mirrors `artist_albums` in
    /// the Linux client.
    func albumsForArtist(_ name: String) -> (credited: [Album], appearsOn: [Album]) {
        let key = artistMatchKey(name)
        var credited: [Album] = []
        var appearsOn: [Album] = []
        for album in library.albums {
            if artistMatchKey(album.artist) == key {
                credited.append(album)
            } else if album.tracks.contains(where: { artistMatchKey($0.artist) == key }) {
                appearsOn.append(album)
            }
        }
        return (credited, appearsOn)
    }

    func refreshPlaylists() {
        cacheLock.lock()
        cachedPlaylists = nil
        cacheLock.unlock()
        guard currentSegment == .playlists else { return }
        publishSnapshot()
    }

    /// Computes play-history-derived suggestions off-main the first time the
    /// Playlists segment is shown, then republishes so they slot in above the
    /// user's lists.
    func loadSuggestionsIfNeeded() {
        guard currentSegment == .playlists,
              cachedSuggestions == nil,
              !suggestionsLoading else { return }
        suggestionsLoading = true
        let pool = library.allTracks
        Task.detached(priority: .utility) { [weak self] in
            let suggestions = SuggestedPlaylistService.build(pool: HideDuplicateSongsSetting.uniquePool(pool))
            await MainActor.run {
                guard let self else { return }
                self.cachedSuggestions = suggestions
                self.suggestionsLoading = false
                if self.currentSegment == .playlists {
                    self.publishSnapshot()
                }
            }
        }
    }

    func search(query: String) {
        searchQuery = query
        searchDebounceTask?.cancel()
        searchDebounceTask = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            publishSnapshot()
        }
    }

    static func searchFold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    /// Folded "title artist album" haystacks keyed by file URL, computed once
    /// per library generation so typing in search does plain substring scans
    /// instead of locale-aware compares over every track.
    func songSearchKeys() -> [String: String] {
        if let cached = cachedSongSearchKeys { return cached }
        var map = [String: String]()
        let tracks = library.allTracks
        map.reserveCapacity(tracks.count)
        for track in tracks {
            map[track.fileURL.absoluteString] = Self.searchFold("\(track.title)\n\(track.artist)\n\(track.albumTitle)")
        }
        cachedSongSearchKeys = map
        return map
    }

    /// Keeps one copy of each song in the visible list, preferring the copy the
    /// person loved and then the one they have played, so a Favorites or
    /// Recently Played pivot never loses a row to a twin it has no history for.
    func collapsingDuplicates(in songs: [Track]) -> [Track] {
        guard HideDuplicateSongsSetting.isEnabled else {
            duplicateCopies = [:]
            return songs
        }
        let result = LibraryHygiene.collapsingDuplicateSongs(songs) { [self] track in
            (LovedTracksService.shared.isLoved(track: track) ? 2 : 0) + (meta(for: track)?.lastPlayed != nil ? 1 : 0)
        }
        duplicateCopies = result.copies
        return result.tracks
    }
}
