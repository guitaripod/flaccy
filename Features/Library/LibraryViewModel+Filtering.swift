import Combine
import MidgarCore
import FlaccyCore

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

extension LibraryViewModel {

    /// The Albums chip and its ordering. Membership and order come from the
    /// shared `LibraryFilterRules` over the warmed album signals, so a click is
    /// a pass over dictionaries — never a scrobble aggregate or a file lookup.
    func filteredAlbums(_ unsourced: [Album]) -> [Album] {
        let albums = source.map { source in Self.narrowing(unsourced, to: source.admits) } ?? unsourced
        switch filter {
        case .all:
            return albums
        case .lossless:
            return albums.filter { representativeTrack(for: $0)?.isLossless == true }
        case .offline:
            return Self.narrowing(albums, to: Self.playsOffline)
        case .favorites:
            return albums.filter { isLovedAlbum($0) }
        case .recentlyAdded:
            let added = filterSignals().added
            let ids = LibraryFilterRules.recentlyAdded(
                albums.map { (id: Self.albumFilterKey($0), dateAdded: added[Self.albumFilterKey($0)] ?? .distantPast) },
                now: Date(),
                thresholds: .albums
            )
            return self.albums(albums, for: ids)
        case .recentlyPlayed:
            let played = filterSignals().played
            let ids = LibraryFilterRules.recentlyPlayed(
                albums.map { (id: Self.albumFilterKey($0), lastPlayed: played[Self.albumFilterKey($0)]) },
                now: Date(),
                thresholds: .albums
            )
            return self.albums(albums, for: ids)
        case .rediscover:
            let keys = filterSignals().rediscover.keys
            return albums.filter { keys.contains(Self.albumFilterKey($0)) }
        }
    }

    /// The Songs chip and its ordering, by the same shared rules: a 30-day
    /// window that falls back to the newest songs, everything played when the
    /// window is thin, and Rediscover's albums standing for their songs.
    func filteredSongs(_ unsourced: [Track]) -> [Track] {
        let songs = source.map { source in unsourced.filter(source.admits) } ?? unsourced
        switch filter {
        case .all:
            return songs
        case .lossless:
            return songs.filter { $0.isLossless }
        case .offline:
            return songs.filter(Self.playsOffline)
        case .favorites:
            return songs.filter { LovedTracksService.shared.isLoved(track: $0) }
        case .recentlyAdded:
            let ids = LibraryFilterRules.recentlyAdded(
                addedEntries(songs), now: Date(), thresholds: .songs
            )
            return self.songs(songs, for: ids)
        case .recentlyPlayed:
            let ids = LibraryFilterRules.recentlyPlayed(
                playedEntries(songs), now: Date(), thresholds: .songs
            )
            return self.songs(songs, for: ids)
        case .rediscover:
            let keys = filterSignals().rediscover.keys
            return songs.filter { keys.contains("\($0.albumTitle)|\($0.artist)") }
        }
    }

    /// Each album with only the songs `admits` lets through, and without the albums left empty, so a source or the
    /// Offline chip shows an album as the part of it that answers to the chip. The album keeps its identity.
    nonisolated static func narrowing(_ albums: [Album], to admits: (Track) -> Bool) -> [Album] {
        albums.compactMap { album in
            let tracks = album.tracks.filter(admits)
            guard !tracks.isEmpty else { return nil }
            guard tracks.count < album.tracks.count else { return album }
            return Album(title: album.title, artist: album.artist, artwork: album.artwork, tracks: tracks, year: album.year, genre: album.genre)
        }
    }

    /// Whether a song plays with no server in reach: a file on this device, or a server song kept whole here.
    nonisolated static func playsOffline(_ track: Track) -> Bool {
        guard let song = track.remoteSong else { return true }
        return RemoteAvailability.shared.isComplete(path: song.path)
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

    /// The name each row on screen is indexed by, in the order the list shows
    /// them. Read from the lists the snapshot was built from, so the index
    /// still points at the right row when a source chip, a search or Clean
    /// Library leaves fewer rows on screen than the library holds.
    private func indexedNames() -> [String] {
        let query = LibrarySearch.Query(searchQuery)
        switch currentSegment {
        case .albums:
            return matchingAlbums(filteredAlbums(sortedAlbums), query: query).map { albumSort == .artist ? $0.artist : $0.title }
        case .songs:
            return visibleSongs.map { songSort == .artist ? $0.artist : $0.title }
        case .artists:
            return matchingArtists(sortedArtists, query: query).map(\.name)
        case .playlists:
            return []
        }
    }

    private static func indexLetter(of name: String) -> String {
        let first = String(name.prefix(1)).uppercased()
        return first.first?.isLetter == true ? first : "#"
    }

    func indexTitles() -> [String] {
        var seen = Set<String>()
        var titles = [String]()
        for name in indexedNames() {
            let key = Self.indexLetter(of: name)
            if seen.insert(key).inserted {
                titles.append(key)
            }
        }
        return titles
    }

    func indexOfFirstItem(forLetter letter: String) -> Int? {
        indexedNames().firstIndex { Self.indexLetter(of: $0) == letter }
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
            let suggestions = SuggestedPlaylistService.build(pool: CleanLibrarySetting.uniquePool(pool))
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

    /// Each song's title, artist and album folded by the shared search rules
    /// and keyed by file URL, computed once per library generation so typing
    /// in search scans plain text instead of folding every track again.
    func songSearchKeys() -> [String: String] {
        if let cached = cachedSongSearchKeys { return cached }
        var map = [String: String]()
        let tracks = library.allTracks
        map.reserveCapacity(tracks.count)
        for track in tracks {
            map[track.fileURL.absoluteString] = LibrarySearch.haystack([track.title, track.artist, track.albumTitle])
        }
        cachedSongSearchKeys = map
        return map
    }

    /// Keeps one copy of each song in the visible list, preferring the copy the
    /// person loved and then the one they have played, so a Favorites or
    /// Recently Played pivot never loses a row to a twin it has no history for.
    func collapsingDuplicates(in songs: [Track]) -> [Track] {
        guard CleanLibrarySetting.isEnabled else {
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
