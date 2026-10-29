import FlaccyCore
import FlaccyEngine
import Foundation

/// What one catalog sync did to a server's rows.
nonisolated struct RemoteSyncReport: Sendable, Equatable {
    var songs = 0
    var inserted = 0
    var updated = 0
    var newVersions = 0
    var removed = 0
}

/// Keeps the library rows of each server in step with the server's catalog: reads every song,
/// compares it with the rows by the shared `RemoteCatalogDiff`, applies the difference in one
/// transaction, fetches the album covers the library lacks, and tells every screen.
actor RemoteCatalogSync {

    static let shared = RemoteCatalogSync()

    static let staleAfter: TimeInterval = 6 * 3_600
    static let pageSize = 500
    static let albumParallelism = 4
    static let coverSize = 600

    private var running: [String: Task<RemoteSyncReport, Error>] = [:]

    /// Syncs every server whose last sync is older than six hours, or that never synced, and sends the stars that did not reach their server.
    func syncStaleServers(now: Date = Date()) async {
        let servers = (try? await RemoteServers.shared.list()) ?? []
        for server in servers where Self.isStale(server.lastSyncedAt, now: now) && RemoteLibraryVisibility.isShown(serverID: server.id) {
            _ = try? await sync(serverID: server.id)
        }
        await RemoteServerReports.flushPendingStars()
    }

    static func isStale(_ lastSyncedAt: Date?, now: Date) -> Bool {
        guard let lastSyncedAt else { return true }
        return now.timeIntervalSince(lastSyncedAt) > staleAfter
    }

    /// Syncs one server. A sync already running for it is joined rather than started twice.
    @discardableResult
    func sync(serverID: String) async throws -> RemoteSyncReport {
        guard RemoteLibraryVisibility.isShown(serverID: serverID) else { return RemoteSyncReport() }
        if let existing = running[serverID] { return try await existing.value }
        let task = Task { try await self.performSync(serverID: serverID) }
        running[serverID] = task
        defer { running[serverID] = nil }
        return try await task.value
    }

    func cancel(serverID: String) {
        running[serverID]?.cancel()
        running[serverID] = nil
    }

    /// Announces songs that left the library with their server, as a local reload announces deleted files.
    func publishRemoval(paths: [String]) async {
        let urls = Set(paths.compactMap { RemoteTrackPath(path: $0)?.assetURL })
        await MainActor.run {
            if !urls.isEmpty { AudioPlayer.shared.handleDeletedTracks(urls) }
        }
        await publishLibraryChange()
    }

    /// Records that the server serves new bytes under a song's name, found while streaming it.
    func noteNewVersion(path: String, size: Int64?) async {
        guard (try? DatabaseManager.shared.bumpRemoteRevision(path: path, size: size, now: Date())) == true else { return }
        RemoteSongDirectory.shared.invalidate(paths: [path])
        await publishLibraryChange()
        await announceRevisions([path])
    }

    private func performSync(serverID: String) async throws -> RemoteSyncReport {
        let record = try? DatabaseManager.shared.fetchRemoteServer(id: serverID)
        RemoteSyncStatus.shared.begin(
            serverID: serverID, name: record?.name ?? serverID, isFirstSync: record?.lastSyncedAt == nil
        )
        do {
            let report = try await runSync(serverID: serverID)
            await ServerSyncService.engine.resolveGhosts()
            RemoteAvailability.shared.setReachable(serverID: serverID, true)
            RemoteSyncStatus.shared.finish(serverID: serverID, failure: nil)
            return report
        } catch is CancellationError {
            RemoteSyncStatus.shared.finish(serverID: serverID, failure: nil)
            throw CancellationError()
        } catch {
            let host = await RemoteServers.shared.displayHost(for: serverID)
            let failure = RemoteFailure.from(error, host: host)
            switch failure {
            case .unreachable, .tlsFailure: RemoteAvailability.shared.setReachable(serverID: serverID, false)
            default: break
            }
            RemoteSyncStatus.shared.finish(serverID: serverID, failure: failure.errorDescription)
            RemoteLog.error("Sync of \(host) failed: \(failure.errorDescription ?? "unknown")")
            throw failure
        }
    }

    private func runSync(serverID: String) async throws -> RemoteSyncReport {
        let client = try await RemoteServers.shared.client(for: serverID)
        let database = DatabaseManager.shared
        let started = Date()
        Task { if let total = await client.songTotal() { RemoteSyncStatus.shared.update(serverID: serverID, songTotal: total) } }
        let songs = try await fetchAllSongs(client)
        try Task.checkCancellation()
        let server = songs.map(Self.item(from:))
        let local = try database.fetchRemoteCatalogItems(serverID: serverID)
        let diff = RemoteCatalogDiff.diff(server: server, local: local)
        let byID = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func entries(_ ids: [String]) -> [(songID: String, facts: RemoteSongFacts)] {
            ids.compactMap { id in byID[id].map { (songID: id, facts: Self.facts(from: $0)) } }
        }
        let change = RemoteCatalogChange(
            serverID: serverID,
            inserts: entries(diff.inserted),
            updates: entries(diff.updated),
            newVersions: entries(diff.newVersions),
            removedSongIDs: diff.removed,
            playStates: songs.map(Self.playState(of:)),
            now: started
        )
        try database.applyRemoteCatalog(change)
        let touched = (diff.updated + diff.newVersions + diff.removed).map { RemoteTrackPath(serverID: serverID, songID: $0).path }
        RemoteSongDirectory.shared.invalidate(paths: touched)
        let dropped = diff.newVersions.map { RemoteTrackPath(serverID: serverID, songID: $0) }
        let removedSongs = diff.removed.map { RemoteTrackPath(serverID: serverID, songID: $0) }
        await RemoteStreamCache.shared.discardFiles(of: removedSongs)
        RemoteAvailability.shared.forget(paths: removedSongs.map(\.path))
        await RemoteStreamCache.shared.replaceFilesOfNewVersions(dropped)
        try database.markRemoteServerSynced(id: serverID, at: Date())
        let coversAdded = await fetchMissingCovers(client: client, songs: songs.map(Self.facts(from:)))
        await publishLibraryChange(covers: coversAdded)
        if !diff.newVersions.isEmpty {
            await announceRevisions(diff.newVersions.map { RemoteTrackPath(serverID: serverID, songID: $0).path })
        }
        let report = RemoteSyncReport(
            songs: songs.count,
            inserted: diff.inserted.count,
            updated: diff.updated.count,
            newVersions: diff.newVersions.count,
            removed: diff.removed.count
        )
        RemoteLog.info("Synced \(client.host): \(report.songs) songs, \(report.inserted) new, \(report.updated) changed, \(report.newVersions) new versions, \(report.removed) removed")
        return report
    }

    /// Every song of the server through `search3` pages; a server that answers an empty query with nothing is read album by album.
    private func fetchAllSongs(_ client: SubsonicClient) async throws -> [SubsonicResponse.Child] {
        var songs: [SubsonicResponse.Child] = []
        var seen = Set<String>()
        var offset = 0
        var previousFirst: String?
        while true {
            try Task.checkCancellation()
            let page = try await client.songsPage(offset: offset, size: Self.pageSize)
            guard let first = page.first, first.id != previousFirst else { break }
            previousFirst = first.id
            for song in page where seen.insert(song.id).inserted { songs.append(song) }
            offset += page.count
            RemoteSyncStatus.shared.update(serverID: client.serverID, songsRead: songs.count)
        }
        if songs.isEmpty { return try await fetchSongsAlbumByAlbum(client) }
        return songs
    }

    private func fetchSongsAlbumByAlbum(_ client: SubsonicClient) async throws -> [SubsonicResponse.Child] {
        var albumIDs: [String] = []
        var offset = 0
        var previousFirst: String?
        while true {
            try Task.checkCancellation()
            let page = try await client.albumsPage(offset: offset, size: Self.pageSize)
            guard let first = page.first, first.id != previousFirst else { break }
            previousFirst = first.id
            albumIDs.append(contentsOf: page.map(\.id))
            offset += page.count
        }
        var songs: [SubsonicResponse.Child] = []
        var seen = Set<String>()
        try await withThrowingTaskGroup(of: [SubsonicResponse.Child].self) { group in
            var pending = albumIDs.makeIterator()
            func addNext(_ group: inout ThrowingTaskGroup<[SubsonicResponse.Child], Error>) -> Bool {
                guard let id = pending.next() else { return false }
                group.addTask { try await client.album(id: id).song ?? [] }
                return true
            }
            for _ in 0..<Self.albumParallelism { _ = addNext(&group) }
            for try await batch in group {
                for song in batch where seen.insert(song.id).inserted { songs.append(song) }
                RemoteSyncStatus.shared.update(serverID: client.serverID, songsRead: songs.count)
                _ = addNext(&group)
            }
        }
        return songs
    }

    /// Fetches the cover of every album the library has no cover for, once per album, a few at a time.
    private func fetchMissingCovers(client: SubsonicClient, songs: [RemoteSongFacts]) async -> [(title: String, artist: String)] {
        let database = DatabaseManager.shared
        var wanted: [String: (title: String, artist: String, coverArt: String)] = [:]
        for song in songs {
            guard let coverArt = song.coverArt, !song.albumTitle.isEmpty else { continue }
            let key = song.albumTitle + "\u{0}" + song.artist
            guard wanted[key] == nil else { continue }
            let hasCover = (try? database.fetchAlbumInfoStatus(title: song.albumTitle, artist: song.artist).hasCover) ?? false
            if !hasCover { wanted[key] = (song.albumTitle, song.artist, coverArt) }
        }
        var added: [(title: String, artist: String)] = []
        await withTaskGroup(of: (title: String, artist: String)?.self) { group in
            var pending = wanted.values.makeIterator()
            func addNext(_ group: inout TaskGroup<(title: String, artist: String)?>) -> Bool {
                guard let album = pending.next() else { return false }
                group.addTask {
                    guard let data = try? await client.coverArt(id: album.coverArt, size: Self.coverSize) else { return nil }
                    do {
                        try database.saveAlbumCoverArtIfMissing(title: album.title, artist: album.artist, data: data)
                        return (album.title, album.artist)
                    } catch {
                        RemoteLog.error("Could not store a cover: \(error.localizedDescription)")
                        return nil
                    }
                }
                return true
            }
            for _ in 0..<Self.albumParallelism { _ = addNext(&group) }
            for await result in group {
                if let result { added.append(result) }
                _ = addNext(&group)
            }
        }
        return added
    }

    private func publishLibraryChange(covers: [(title: String, artist: String)] = []) async {
        await MainActor.run {
            if !covers.isEmpty { AlbumArtworkCache.shared.invalidate(keys: covers) }
            LovedTracksService.shared.reloadFromDatabase()
        }
        await Self.reloadLibrary()
    }

    @MainActor
    private static func reloadLibrary() async {
        await Library.shared.reloadFromDatabase()
    }

    private func announceRevisions(_ paths: [String]) async {
        await MainActor.run {
            NotificationCenter.default.post(
                name: Library.tracksRevised,
                object: nil,
                userInfo: [Library.RevisionKey.paths: paths]
            )
        }
    }
}

extension RemoteCatalogSync {

    nonisolated static func item(from child: SubsonicResponse.Child) -> RemoteCatalogDiff.Item {
        let facts = facts(from: child)
        return RemoteCatalogDiff.Item(
            id: child.id,
            size: facts.size,
            duration: facts.duration,
            title: facts.title,
            artist: facts.artist,
            album: facts.albumTitle,
            track: facts.trackNumber,
            fingerprint: facts.fingerprint
        )
    }

    nonisolated static func facts(from child: SubsonicResponse.Child) -> RemoteSongFacts {
        RemoteSongFacts(
            title: child.title,
            artist: nonEmpty(child.artist) ?? nonEmpty(child.displayArtist) ?? "Unknown Artist",
            albumTitle: nonEmpty(child.album) ?? "Unknown Album",
            albumArtist: nonEmpty(child.displayAlbumArtist),
            trackNumber: child.track ?? 0,
            duration: child.duration ?? 0,
            suffix: nonEmpty(child.suffix)?.lowercased(),
            size: child.size,
            coverArt: nonEmpty(child.coverArt),
            albumId: nonEmpty(child.albumId),
            codec: codec(suffix: child.suffix, bitDepth: child.bitDepth),
            bitDepth: positive(child.bitDepth),
            sampleRate: positive(child.samplingRate),
            channels: positive(child.channelCount),
            fingerprint: nonEmpty(child.flaccyFingerprint)
        )
    }

    nonisolated static func playState(of child: SubsonicResponse.Child) -> RemoteSongPlayState {
        RemoteSongPlayState(
            songID: child.id,
            starred: child.starred != nil,
            playCount: child.playCount,
            played: child.played.flatMap(parseDate)
        )
    }

    /// The codec names the library's own files carry, derived from the suffix; a `.m4a` with a bit depth is lossless.
    nonisolated static func codec(suffix: String?, bitDepth: Int?) -> String? {
        switch (suffix ?? "").lowercased() {
        case "": nil
        case "m4a", "mp4": (bitDepth ?? 0) > 0 ? "ALAC" : "AAC"
        case "aif", "aiff": "AIFF"
        case "wave": "WAV"
        case let other: other.uppercased()
        }
    }

    nonisolated static func parseDate(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }

    nonisolated private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    nonisolated private static func positive(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }
}
