import AVFoundation
import Foundation

nonisolated enum WantlistState: String, Sendable {
    case wanted, dismissed, acquired
}

nonisolated enum WantlistKind: String, Sendable {
    case album, track, artist
}

nonisolated enum WantlistSource: String, Sendable {
    case history, loved, discovery, gap, upgrade, manual
}

/// Owns the persistent wantlist: merges freshly computed suggestions into the
/// store without resurrecting dismissed or acquired rows, resolves wanted rows
/// against the library after every sync, and caches the new-release watch.
final class WantlistService {

    static let shared = WantlistService()

    static let didResolveItems = Notification.Name("WantlistDidResolveItems")
    static let didChange = Notification.Name("WantlistDidChange")

    private let database = DatabaseManager.shared
    private var libraryObserver: NSObjectProtocol?

    private static let releaseTTL: TimeInterval = 7 * 24 * 3600
    private static let releaseWindow: TimeInterval = 120 * 24 * 3600
    private static let releaseArtistLimit = 15

    private init() {
        libraryObserver = NotificationCenter.default.addObserver(
            forName: Library.didUpdateNotification, object: nil, queue: .main
        ) { _ in
            Task { WantlistService.shared.resolveAgainstLibrary() }
        }
    }

    static func normKey(kind: WantlistKind, title: String, artist: String) -> String {
        kind.rawValue + "\u{0}" + WantlistOwnership.matchKey(title: title, artist: artist)
    }

    func wantedItems() -> [WantlistRecord] {
        (try? database.fetchWantlist(states: [WantlistState.wanted.rawValue])) ?? []
    }

    func merge(suggestions: [WantlistRecord]) {
        do {
            try database.mergeWantlistSuggestions(suggestions)
        } catch {
            AppLogger.error("Wantlist merge failed: \(error.localizedDescription)", category: .database)
        }
    }

    func addManual(kind: WantlistKind, title: String, artist: String, imageURL: String?) {
        let record = WantlistRecord(
            normKey: Self.normKey(kind: kind, title: title, artist: artist),
            kind: kind.rawValue, title: title, artist: artist, imageURL: imageURL,
            state: WantlistState.wanted.rawValue, source: WantlistSource.manual.rawValue,
            score: 1000, reason: "Added by you", playCount: 0, addedAt: Date(),
            resolvedAt: nil, acknowledged: true
        )
        merge(suggestions: [record])
        NotificationCenter.default.post(name: Self.didChange, object: nil)
        AppLogger.info("Wantlist manual add: \(title) — \(artist)", category: .content)
    }

    func setState(_ state: WantlistState, normKey: String) {
        do {
            try database.updateWantlistState(
                normKey: normKey, state: state.rawValue,
                resolvedAt: state == .wanted ? nil : Date()
            )
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        } catch {
            AppLogger.error("Wantlist state update failed: \(error.localizedDescription)", category: .database)
        }
    }

    func unseenCount() -> Int {
        (try? database.unacknowledgedWantedCount()) ?? 0
    }

    func markAllSeen() {
        try? database.acknowledgeWantlist()
    }

    /// Crosses off wanted rows the library now covers and announces the wins.
    /// Gap and upgrade rows describe an already-owned album, so they resolve
    /// when the deficiency disappears (album completed / re-ripped lossless),
    /// and quietly retire if the album leaves the library altogether.
    func resolveAgainstLibrary() {
        let albums = Library.shared.albums
        let ownership = WantlistOwnership(albums: albums, tracks: Library.shared.allTracks)
        let openDeficiencies = Set(Self.localSuggestions(albums: albums).map(\.normKey))
        let wanted = wantedItems()
        var resolved: [WantlistRecord] = []
        for item in wanted {
            let source = WantlistSource(rawValue: item.source)
            if source == .gap || source == .upgrade {
                guard !openDeficiencies.contains(item.normKey) else { continue }
                if ownership.ownsAlbum(name: item.title, artist: item.artist) {
                    do {
                        try database.updateWantlistState(
                            normKey: item.normKey, state: WantlistState.acquired.rawValue, resolvedAt: Date()
                        )
                        resolved.append(item)
                    } catch {
                        AppLogger.error("Wantlist resolve write failed for \(item.normKey): \(error.localizedDescription)", category: .database)
                    }
                } else {
                    do {
                        try database.updateWantlistState(
                            normKey: item.normKey, state: WantlistState.dismissed.rawValue, resolvedAt: Date()
                        )
                    } catch {
                        AppLogger.error("Wantlist retire write failed for \(item.normKey): \(error.localizedDescription)", category: .database)
                    }
                }
                continue
            }
            let owned: Bool
            switch WantlistKind(rawValue: item.kind) {
            case .album: owned = ownership.ownsAlbum(name: item.title, artist: item.artist)
            case .track: owned = ownership.ownsTrack(title: item.title, artist: item.artist)
            case .artist: owned = ownership.hasArtist(item.artist)
            case nil: owned = false
            }
            guard owned else { continue }
            do {
                try database.updateWantlistState(
                    normKey: item.normKey, state: WantlistState.acquired.rawValue, resolvedAt: Date()
                )
                resolved.append(item)
            } catch {
                AppLogger.error("Wantlist resolve write failed for \(item.normKey): \(error.localizedDescription)", category: .database)
            }
        }
        guard !resolved.isEmpty else { return }
        let names = resolved.map { $0.kind == WantlistKind.artist.rawValue ? $0.artist : $0.title }
        AppLogger.info("Wantlist resolved \(resolved.count) items: \(names.joined(separator: ", "))", category: .content)
        NotificationCenter.default.post(name: Self.didResolveItems, object: nil, userInfo: ["names": names])
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// Gap: album where the highest track number exceeds the owned count.
    /// Upgrade: album where every track with a known codec is lossy.
    nonisolated static func localSuggestions(albums: [Album]) -> [WantlistRecord] {
        var records: [WantlistRecord] = []
        let now = Date()
        for album in albums {
            let owned = album.tracks.count
            let total = album.tracks.map(\.trackNumber).max() ?? 0
            if owned >= 2, total > owned, total <= 50 {
                records.append(WantlistRecord(
                    normKey: normKey(kind: .album, title: album.title, artist: album.artist) + "\u{0}gap",
                    kind: WantlistKind.album.rawValue, title: album.title, artist: album.artist,
                    imageURL: nil, state: WantlistState.wanted.rawValue, source: WantlistSource.gap.rawValue,
                    score: 800 + Double(owned) / Double(total) * 100,
                    reason: "You own \(owned) of \(total) tracks",
                    playCount: 0, addedAt: now, resolvedAt: nil, acknowledged: false
                ))
            }

            let codecs = album.tracks.compactMap(\.codec)
            if codecs.count == album.tracks.count, !album.tracks.isEmpty, album.tracks.allSatisfy({ !$0.isLossless }) {
                let codec = codecs.first?.uppercased() ?? "lossy"
                records.append(WantlistRecord(
                    normKey: normKey(kind: .album, title: album.title, artist: album.artist) + "\u{0}upgrade",
                    kind: WantlistKind.album.rawValue, title: album.title, artist: album.artist,
                    imageURL: nil, state: WantlistState.wanted.rawValue, source: WantlistSource.upgrade.rawValue,
                    score: 300,
                    reason: "In library as \(codec) — get it lossless",
                    playCount: 0, addedAt: now, resolvedAt: nil, acknowledged: false
                ))
            }
        }
        return records
    }

    // MARK: New-release watch

    func cachedNewReleases() -> [NewReleaseRecord] {
        ((try? database.fetchNewReleases()) ?? []).filter {
            $0.releaseDate > Date().addingTimeInterval(-Self.releaseWindow)
        }
    }

    /// Refreshes the release cache from the iTunes Search API at most once per
    /// week, watching the listener's top local artists plus wantlisted artists.
    func refreshNewReleasesIfStale(topArtists: [String]) async -> Bool {
        if let fetchedAt = (try? database.newReleasesFetchedAt()) ?? nil,
           Date().timeIntervalSince(fetchedAt) < Self.releaseTTL {
            return false
        }
        let ownership = await MainActor.run {
            WantlistOwnership(albums: Library.shared.albums, tracks: Library.shared.allTracks)
        }
        let wantedArtists = wantedItems().map(\.artist)
        var seen = Set<String>()
        let watchlist = (topArtists + wantedArtists)
            .filter { seen.insert($0.lowercased()).inserted }
            .prefix(Self.releaseArtistLimit)

        var releases: [NewReleaseRecord] = []
        var failedArtists: [String] = []
        let cutoff = Date().addingTimeInterval(-Self.releaseWindow)
        for (index, artist) in watchlist.enumerated() {
            if index > 0 {
                try? await Task.sleep(for: .seconds(1))
            }
            guard let found = await Self.fetchITunesAlbums(artist: artist) else {
                failedArtists.append(artist)
                continue
            }
            for album in found {
                guard album.releaseDate > cutoff,
                      !ownership.ownsAlbum(name: album.albumTitle, artist: album.artist) else { continue }
                releases.append(album)
            }
        }
        if !failedArtists.isEmpty {
            AppLogger.error("New-release watch: fetch failed for \(failedArtists.joined(separator: ", "))", category: .content)
            let failed = Set(failedArtists.map { $0.lowercased() })
            let retained = ((try? database.fetchNewReleases()) ?? []).filter { failed.contains($0.artist.lowercased()) }
            releases.append(contentsOf: retained)
        }
        do {
            try database.replaceNewReleases(releases)
            AppLogger.info("New-release watch: \(releases.count) releases across \(watchlist.count) artists", category: .content)
        } catch {
            AppLogger.error("New-release cache write failed: \(error.localizedDescription)", category: .database)
        }
        return true
    }

    private nonisolated static func fetchITunesAlbums(artist: String) async -> [NewReleaseRecord]? {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: artist),
            URLQueryItem(name: "entity", value: "album"),
            URLQueryItem(name: "attribute", value: "artistTerm"),
            URLQueryItem(name: "limit", value: "25"),
        ]
        guard let url = components.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return nil }

        let formatter = ISO8601DateFormatter()
        let now = Date()
        return results.compactMap { entry in
            guard let name = entry["collectionName"] as? String,
                  let resultArtist = entry["artistName"] as? String,
                  resultArtist.caseInsensitiveCompare(artist) == .orderedSame,
                  let dateString = entry["releaseDate"] as? String,
                  let releaseDate = formatter.date(from: dateString) else { return nil }
            return NewReleaseRecord(
                artist: resultArtist,
                albumTitle: name,
                releaseDate: releaseDate,
                imageURL: (entry["artworkUrl100"] as? String)?.replacingOccurrences(of: "100x100", with: "600x600"),
                storeURL: entry["collectionViewUrl"] as? String,
                fetchedAt: now
            )
        }
    }

    // MARK: Previews

    nonisolated static func fetchPreviewURL(title: String, artist: String) async -> URL? {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: "\(artist) \(title)"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "5"),
        ]
        guard let url = components.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return nil }
        let match = results.first {
            ($0["artistName"] as? String)?.caseInsensitiveCompare(artist) == .orderedSame
        } ?? results.first
        guard let preview = match?["previewUrl"] as? String else { return nil }
        return URL(string: preview)
    }
}

/// Plays 30-second iTunes previews without disturbing the main queue beyond a
/// pause, and stops itself when the clip ends.
final class PreviewPlayer {

    static let shared = PreviewPlayer()

    private var player: AVPlayer?
    private var endObserver: NSObjectProtocol?
    private(set) var currentKey: String?

    private init() {}

    func toggle(key: String, url: URL) {
        if currentKey == key {
            stop()
            return
        }
        stop()
        if AudioPlayer.shared.isPlaying {
            AudioPlayer.shared.togglePlayPause()
        }
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            self?.stop()
        }
        self.player = player
        currentKey = key
        player.play()
        AppLogger.info("Preview started: \(key)", category: .playback)
    }

    func stop() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        player?.pause()
        player = nil
        currentKey = nil
    }
}
