import Combine
import UIKit

nonisolated enum LibraryItem: Hashable, Sendable {
    case album(Album)
    case song(Track)
    case artist(ArtistItem)
    case playlist(PlaylistItem)
    case charts
}

nonisolated struct ArtistItem: Hashable, Sendable {
    let name: String
    let albumCount: Int
    let artwork: UIImage?

    nonisolated static func == (lhs: ArtistItem, rhs: ArtistItem) -> Bool {
        lhs.name == rhs.name
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(name)
    }
}

nonisolated struct PlaylistItem: Hashable, Sendable {
    let id: Int64
    let name: String
    let trackCount: Int

    nonisolated static func == (lhs: PlaylistItem, rhs: PlaylistItem) -> Bool {
        lhs.id == rhs.id
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

final class LibraryViewModel {

    enum Segment: Int, CaseIterable {
        case albums
        case songs
        case artists
        case playlists
    }

    enum AlbumSort: String, CaseIterable {
        case title, artist, year, recentlyAdded

        var displayName: String {
            switch self {
            case .title: "Title"
            case .artist: "Artist"
            case .year: "Year"
            case .recentlyAdded: "Recently Added"
            }
        }

        var icon: String {
            switch self {
            case .title: "textformat.abc"
            case .artist: "person"
            case .year: "calendar"
            case .recentlyAdded: "clock"
            }
        }
    }

    enum SongSort: String, CaseIterable {
        case title, artist, recentlyPlayed, dateAdded

        var displayName: String {
            switch self {
            case .title: "Title"
            case .artist: "Artist"
            case .recentlyPlayed: "Recently Played"
            case .dateAdded: "Date Added"
            }
        }

        var icon: String {
            switch self {
            case .title: "textformat.abc"
            case .artist: "person"
            case .recentlyPlayed: "clock"
            case .dateAdded: "calendar"
            }
        }
    }

    enum ArtistSort: String, CaseIterable {
        case name, albumCount

        var displayName: String {
            switch self {
            case .name: "Name"
            case .albumCount: "Album Count"
            }
        }

        var icon: String {
            switch self {
            case .name: "textformat.abc"
            case .albumCount: "number"
            }
        }
    }

    typealias Snapshot = NSDiffableDataSourceSnapshot<Int, LibraryItem>

    private let library: LibraryProviding
    private let audioPlayer: AudioPlaying

    let snapshotPublisher = PassthroughSubject<Snapshot, Never>()
    let miniPlayerStatePublisher = PassthroughSubject<MiniPlayerState?, Never>()
    let loadingPublisher = PassthroughSubject<Bool, Never>()

    struct MiniPlayerState {
        let track: Track
        let isPlaying: Bool
    }

    private(set) var currentSegment: Segment = .albums
    private var searchQuery: String = ""
    private(set) var albumSort: AlbumSort = AlbumSort(rawValue: UserDefaults.standard.string(forKey: "albumSort") ?? "") ?? .title
    private(set) var songSort: SongSort = SongSort(rawValue: UserDefaults.standard.string(forKey: "songSort") ?? "") ?? .title
    private(set) var artistSort: ArtistSort = ArtistSort(rawValue: UserDefaults.standard.string(forKey: "artistSort") ?? "") ?? .name

    var isEmpty: Bool {
        switch currentSegment {
        case .albums: return library.albums.isEmpty
        case .songs: return library.allTracks.isEmpty
        case .artists: return artists.isEmpty
        case .playlists: return playlists.isEmpty && !LastFMService.shared.isAuthenticated
        }
    }

    var sortedAlbums: [Album] {
        switch albumSort {
        case .title:
            return library.albums.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .artist:
            return library.albums.sorted {
                let cmp = $0.artist.localizedCaseInsensitiveCompare($1.artist)
                return cmp == .orderedSame ? $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending : cmp == .orderedAscending
            }
        case .year:
            return library.albums.sorted {
                let y0 = $0.year ?? "9999"
                let y1 = $1.year ?? "9999"
                return y0 == y1 ? $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending : y0 < y1
            }
        case .recentlyAdded:
            let dateAdded: [String: Date]
            do {
                let rows = try DatabaseManager.shared.fetchAllTracks()
                var map = [String: Date]()
                for r in rows {
                    let key = "\(r.albumTitle)\0\(r.artist)"
                    if let existing = map[key] {
                        if r.dateAdded > existing { map[key] = r.dateAdded }
                    } else {
                        map[key] = r.dateAdded
                    }
                }
                dateAdded = map
            } catch { dateAdded = [:] }
            return library.albums.sorted {
                let d0 = dateAdded["\($0.title)\0\($0.artist)"] ?? .distantPast
                let d1 = dateAdded["\($1.title)\0\($1.artist)"] ?? .distantPast
                return d0 > d1
            }
        }
    }

    var sortedSongs: [Track] {
        let tracks = library.allTracks
        guard !tracks.isEmpty else { return tracks }

        switch songSort {
        case .title:
            return tracks.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .artist:
            return tracks.sorted {
                let cmp = $0.artist.localizedCaseInsensitiveCompare($1.artist)
                return cmp == .orderedSame ? $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending : cmp == .orderedAscending
            }
        case .recentlyPlayed:
            let sortKeys: [(fileURL: String, lastPlayed: Date?)]
            do {
                sortKeys = try DatabaseManager.shared.fetchTrackSortKeys()
            } catch {
                return tracks.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            }
            let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].standardizedFileURL
            var lastPlayedByURL = [URL: Date]()
            for key in sortKeys {
                if let date = key.lastPlayed {
                    lastPlayedByURL[docsDir.appendingPathComponent(key.fileURL)] = date
                }
            }
            let played = tracks.filter { lastPlayedByURL[$0.fileURL] != nil }
                .sorted { (lastPlayedByURL[$0.fileURL] ?? .distantPast) > (lastPlayedByURL[$1.fileURL] ?? .distantPast) }
            let unplayed = tracks.filter { lastPlayedByURL[$0.fileURL] == nil }
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            return played + unplayed
        case .dateAdded:
            return tracks
        }
    }

    var sortedArtists: [ArtistItem] {
        switch artistSort {
        case .name:
            return artists.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .albumCount:
            return artists.sorted { $0.albumCount > $1.albumCount }
        }
    }

    var recentlyPlayedAlbums: [Album] {
        do {
            let recent = try DatabaseManager.shared.fetchRecentlyPlayedAlbums(limit: 6)
            return recent.compactMap { pair in
                library.albums.first { $0.title == pair.albumTitle && $0.artist == pair.artist }
            }
        } catch { return [] }
    }

    var playlists: [PlaylistItem] {
        do {
            let records = try DatabaseManager.shared.fetchAllPlaylists()
            return records.compactMap { record in
                guard let id = record.id else { return nil }
                let count = (try? DatabaseManager.shared.fetchPlaylistTrackCount(playlistId: id)) ?? 0
                return PlaylistItem(id: id, name: record.name, trackCount: count)
            }
        } catch {
            AppLogger.error("Failed to fetch playlists: \(error.localizedDescription)", category: .database)
            return []
        }
    }

    var artists: [ArtistItem] {
        var seen = [String: ArtistItem]()
        for album in library.albums {
            if let existing = seen[album.artist] {
                seen[album.artist] = ArtistItem(
                    name: album.artist,
                    albumCount: existing.albumCount + 1,
                    artwork: existing.artwork ?? album.artwork
                )
            } else {
                seen[album.artist] = ArtistItem(
                    name: album.artist,
                    albumCount: 1,
                    artwork: album.artwork
                )
            }
        }
        return seen.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    init(library: LibraryProviding = Library.shared, audioPlayer: AudioPlaying = AudioPlayer.shared) {
        self.library = library
        self.audioPlayer = audioPlayer

        NotificationCenter.default.addObserver(
            self, selector: #selector(libraryDidUpdate), name: Library.didUpdateNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(playbackDidChange), name: AudioPlayer.trackDidChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(playbackDidChange), name: AudioPlayer.playbackStateDidChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(loadingStateChanged), name: Library.loadingStateChanged, object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func loadLibrary() async {
        await library.reload()
    }

    func restorePlaybackState() {
        audioPlayer.restoreQueueState()
    }

    func importFiles(from urls: [URL]) async {
        await library.importFiles(from: urls)
    }

    func setAlbumSort(_ sort: AlbumSort) {
        albumSort = sort
        UserDefaults.standard.set(sort.rawValue, forKey: "albumSort")
        snapshotPublisher.send(buildSnapshot())
    }

    func setSongSort(_ sort: SongSort) {
        songSort = sort
        UserDefaults.standard.set(sort.rawValue, forKey: "songSort")
        snapshotPublisher.send(buildSnapshot())
    }

    func setArtistSort(_ sort: ArtistSort) {
        artistSort = sort
        UserDefaults.standard.set(sort.rawValue, forKey: "artistSort")
        snapshotPublisher.send(buildSnapshot())
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

    func switchSegment(to segment: Segment) {
        currentSegment = segment
        snapshotPublisher.send(buildSnapshot())
    }

    func albumsForArtist(_ name: String) -> [Album] {
        library.albums.filter { $0.artist == name }
    }

    func refreshPlaylists() {
        guard currentSegment == .playlists else { return }
        snapshotPublisher.send(buildSnapshot())
    }

    func search(query: String) {
        searchQuery = query
        snapshotPublisher.send(buildSnapshot())
    }

    private func buildSnapshot() -> Snapshot {
        var snapshot = Snapshot()
        let query = searchQuery.lowercased()
        switch currentSegment {
        case .albums:
            let all = sortedAlbums
            let filtered = query.isEmpty
                ? all
                : all.filter {
                    $0.title.localizedCaseInsensitiveContains(query)
                        || $0.artist.localizedCaseInsensitiveContains(query)
                        || $0.tracks.contains { $0.title.localizedCaseInsensitiveContains(query) }
                }
            let recent = query.isEmpty ? recentlyPlayedAlbums : []
            if !recent.isEmpty {
                snapshot.appendSections([0, 1])
                snapshot.appendItems(recent.map { .album($0) }, toSection: 0)
                snapshot.appendItems(filtered.map { .album($0) }, toSection: 1)
            } else {
                snapshot.appendSections([0])
                snapshot.appendItems(filtered.map { .album($0) })
            }
        case .songs:
            snapshot.appendSections([0])
            var songs = sortedSongs
            if !query.isEmpty {
                songs = songs.filter {
                    $0.title.localizedCaseInsensitiveContains(query)
                        || $0.artist.localizedCaseInsensitiveContains(query)
                        || $0.albumTitle.localizedCaseInsensitiveContains(query)
                }
            }
            snapshot.appendItems(songs.map { .song($0) })
        case .artists:
            snapshot.appendSections([0])
            let filtered = query.isEmpty
                ? sortedArtists
                : sortedArtists.filter { $0.name.localizedCaseInsensitiveContains(query) }
            snapshot.appendItems(filtered.map { .artist($0) })
        case .playlists:
            snapshot.appendSections([0])
            var playlistItems: [LibraryItem] = []
            if LastFMService.shared.isAuthenticated && query.isEmpty {
                playlistItems.append(.charts)
            }
            let filtered = query.isEmpty
                ? playlists
                : playlists.filter { $0.name.localizedCaseInsensitiveContains(query) }
            playlistItems.append(contentsOf: filtered.map { .playlist($0) })
            snapshot.appendItems(playlistItems)
        }
        return snapshot
    }

    private func publishMiniPlayerState() {
        if let track = audioPlayer.currentTrack {
            miniPlayerStatePublisher.send(MiniPlayerState(track: track, isPlaying: audioPlayer.isPlaying))
        } else {
            miniPlayerStatePublisher.send(nil)
        }
    }

    @objc private func libraryDidUpdate() {
        snapshotPublisher.send(buildSnapshot())
    }

    @objc private func playbackDidChange() {
        publishMiniPlayerState()
    }

    @objc private func loadingStateChanged() {
        loadingPublisher.send(library.isLoading)
    }
}
