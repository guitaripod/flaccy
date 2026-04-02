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

    var isEmpty: Bool {
        switch currentSegment {
        case .albums: return library.albums.isEmpty
        case .songs: return library.allTracks.isEmpty
        case .artists: return artists.isEmpty
        case .playlists: return playlists.isEmpty
        }
    }

    var albums: [Album] { library.albums }

    var sortedSongs: [Track] {
        do {
            let records = try DatabaseManager.shared.fetchAllTracks()
            let played = records.filter { $0.lastPlayed != nil }.sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
            let unplayed = records.filter { $0.lastPlayed == nil }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            return (played + unplayed).map { record in
                let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].standardizedFileURL
                let artwork: UIImage?
                if let data = record.artworkData {
                    artwork = UIImage(data: data)
                } else if let albumInfo = try? DatabaseManager.shared.fetchAlbumInfo(title: record.albumTitle, artist: record.artist),
                          let artData = albumInfo.coverArtData {
                    artwork = UIImage(data: artData)
                } else {
                    artwork = nil
                }
                return Track(
                    fileURL: docsDir.appendingPathComponent(record.fileURL),
                    title: record.title,
                    artist: record.artist,
                    albumTitle: record.albumTitle,
                    trackNumber: record.trackNumber,
                    duration: record.duration,
                    artwork: artwork,
                    dbID: record.id
                )
            }
        } catch {
            return library.allTracks
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
            let filtered = query.isEmpty
                ? library.albums
                : library.albums.filter {
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
                ? artists
                : artists.filter { $0.name.localizedCaseInsensitiveContains(query) }
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
