import Combine
import MidgarCore
import FlaccyCore

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

extension LibraryViewModel {

    func buildSnapshot() -> Snapshot {
        var snapshot = Snapshot()
        let query = Self.searchFold(searchQuery)
        switch currentSegment {
        case .albums:
            let all = filteredAlbums(sortedAlbums)
            let filtered = query.isEmpty
                ? all
                : all.filter {
                    Self.searchFold($0.title).contains(query)
                        || Self.searchFold($0.artist).contains(query)
                }
            let showsRecentShelf = query.isEmpty && filter == .all && layoutMode == .grid && albumSort == .title
            let recent = showsRecentShelf ? recentlyPlayedAlbums : []
            if !recent.isEmpty {
                snapshot.appendSections([0, 1])
                snapshot.appendItems(recent.map { .recentAlbum($0) }, toSection: 0)
                snapshot.appendItems(filtered.map { .album($0) }, toSection: 1)
            } else {
                snapshot.appendSections([0])
                snapshot.appendItems(filtered.map { .album($0) })
            }
            repaint(retitledItems(albums: filtered, recent: recent), in: &snapshot)
        case .songs:
            snapshot.appendSections([0])
            var songs = filteredSongs(sortedSongs)
            if !query.isEmpty {
                let keys = songSearchKeys()
                songs = songs.filter { track in
                    if let key = keys[track.fileURL.path] { return key.contains(query) }
                    return Self.searchFold("\(track.title)\n\(track.artist)\n\(track.albumTitle)").contains(query)
                }
            }
            songs = collapsingDuplicates(in: songs)
            visibleSongs = songs
            snapshot.appendItems(songs.map { .song($0) })
            repaint(revisedSongItems(in: songs), in: &snapshot)
        case .artists:
            snapshot.appendSections([0])
            let filtered = query.isEmpty
                ? sortedArtists
                : sortedArtists.filter { Self.searchFold($0.name).contains(query) }
            snapshot.appendItems(filtered.map { .artist($0) })
        case .playlists:
            snapshot.appendSections([0])
            var playlistItems: [LibraryItem] = []
            if query.isEmpty {
                playlistItems.append(.charts)
                playlistItems.append(.wantlist)
                playlistItems.append(contentsOf: (cachedSuggestions ?? []).map { .suggestedPlaylist($0) })
            }
            let filtered = query.isEmpty
                ? playlists
                : playlists.filter { Self.searchFold($0.name).contains(query) }
            playlistItems.append(contentsOf: filtered.map { .playlist($0) })
            snapshot.appendItems(playlistItems)
        }
        emptyState = computeEmptyState(itemCount: snapshot.numberOfItems)
        return snapshot
    }

    /// Repaints rows in place. UIKit reconfigures a cell without rebuilding it;
    /// AppKit's snapshot has no such call, so the Mac reloads the same rows.
    func repaint(_ items: [LibraryItem], in snapshot: inout Snapshot) {
        guard !items.isEmpty else { return }
        #if canImport(UIKit)
        snapshot.reconfigureItems(items)
        #else
        snapshot.reloadItems(items)
        #endif
    }

    /// The album rows whose identity held but whose words changed — a Groq
    /// retitle during the Debut's second act, a year arriving from enrichment.
    /// The diff moves such a row rather than replacing it, which is the point,
    /// but a moved row is never re-rendered; only an explicit reconfigure
    /// repaints one.
    func retitledItems(albums: [Album], recent: [Album]) -> [LibraryItem] {
        var next = [String: String](minimumCapacity: albums.count + recent.count)
        var changed: [LibraryItem] = []

        cacheLock.lock()
        defer { cacheLock.unlock() }

        func note(_ album: Album, as item: (Album) -> LibraryItem) {
            let key = LibraryItem.identity(of: album)
            let signature = LibraryItem.renderSignature(of: album)
            next[key] = signature
            guard let previous = renderedAlbumSignatures[key], previous != signature else { return }
            changed.append(item(album))
        }

        for album in recent { note(album, as: LibraryItem.recentAlbum) }
        for album in albums { note(album, as: LibraryItem.album) }
        renderedAlbumSignatures = next
        return changed
    }

    func computeEmptyState(itemCount: Int) -> EmptyState {
        guard itemCount == 0 else { return .none }
        return searchQuery.isEmpty ? .noLibrary : .noSearchResults(searchQuery)
    }

    func publishMiniPlayerState() {
        if let track = audioPlayer.currentTrack {
            miniPlayerStatePublisher.send(MiniPlayerState(track: track, isPlaying: audioPlayer.isPlaying))
        } else {
            miniPlayerStatePublisher.send(nil)
        }
    }

    /// The song rows to repaint for the re-exports announced since the last
    /// snapshot: a song keeps its identity across a new mix, so the diff would
    /// leave its row as it was.
    func revisedSongItems(in songs: [Track]) -> [LibraryItem] {
        guard !revisedSongPaths.isEmpty else { return [] }
        defer { revisedSongPaths.removeAll() }
        return songs
            .filter { revisedSongPaths.contains(LibraryPaths.relativePath(of: $0.fileURL)) }
            .map { .song($0) }
    }

    @objc func tracksRevised(_ notification: Notification) {
        let paths = notification.userInfo?[Library.RevisionKey.paths] as? [String] ?? []
        revisedSongPaths.formUnion(paths)
        publishSnapshot(intent: .refreshLibrary)
    }

    @objc func libraryDidUpdate() {
        invalidateSortCaches()
        publishSnapshot(intent: .refreshLibrary)
    }

    func invalidateSortCaches() {
        cacheLock.lock()
        cachedSortedAlbums = nil
        cachedSortedSongs = nil
        cachedSortedArtists = nil
        cachedRecentAlbums = nil
        cachedPlaylists = nil
        cachedSuggestions = nil
        cachedRediscover = nil
        cachedAlbumAdded = nil
        cachedAlbumPlayed = nil
        cachedScrobbleCounts = nil
        cachedRepresentativeTracks = [:]
        cachedFirstAlbumByArtist = nil
        cachedSongSearchKeys = nil
        cacheLock.unlock()
        Self.invalidateSharedMeta()
    }

    @objc func trackDidChange() {
        cachedRecentAlbums = nil
        cachedRediscover = nil
        cachedAlbumPlayed = nil
        Self.invalidateSharedMeta()
        if albumSort == .recentlyPlayed { cachedSortedAlbums = nil }
        if songSort == .recentlyPlayed { cachedSortedSongs = nil }
        publishMiniPlayerState()
    }

    @objc func playbackStateDidChange() {
        publishMiniPlayerState()
    }

    @objc func loadingStateChanged() {
        loadingPublisher.send(library.isLoading)
    }
}
