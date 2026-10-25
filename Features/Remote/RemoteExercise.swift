#if DEBUG
import FlaccyCore
import FlaccyEngine
import Foundation

/// Drives the whole remote library against a real server and logs `REMOTE EXERCISE PASSED` or
/// `REMOTE EXERCISE FAILED: <step>`. Launch with `--exercise-remote --trial-day 2` and the
/// environment variable `FLACCY_EXERCISE_REMOTE=<url>|<user>|<password>`; add `--skip-keychain`
/// on an unsigned Mac build, which the data protection keychain refuses.
///
/// It adds the server, syncs, checks the song count against the server's own `search3`, plays the
/// first FLAC song for three seconds through the real engine with a non-flat equalizer preset and
/// checks that the position advanced and the tap rendered that item, waits for the cache file and
/// compares it with the server's `download`, pins the album, then removes the server and checks
/// that its rows, playlist places, files and secret are gone.
@MainActor
enum RemoteExercise {

    static let launchArgument = "--exercise-remote"
    static let environmentKey = "FLACCY_EXERCISE_REMOTE"

    private struct Failure: Error {
        let step: String
    }

    static func runIfRequested() {
        guard CommandLine.arguments.contains(launchArgument) else { return }
        Task {
            do {
                try await run()
                RemoteLog.info("REMOTE EXERCISE PASSED")
            } catch let failure as Failure {
                RemoteLog.error("REMOTE EXERCISE FAILED: \(failure.step)")
            } catch {
                RemoteLog.error("REMOTE EXERCISE FAILED: \(error.localizedDescription)")
            }
        }
    }

    private static func run() async throws {
        if CommandLine.arguments.contains("--skip-keychain") { RemoteCredentialStore.shared.useMemoryBackend() }
        try await Task.sleep(for: .seconds(3))
        let parts = (ProcessInfo.processInfo.environment[environmentKey] ?? "").components(separatedBy: "|")
        try expect(parts.count == 3, "the environment variable \(environmentKey) holds url|user|password")
        let database = DatabaseManager.shared

        let record = try await RemoteServers.shared.add(
            address: parts[0], name: "Exercise", authentication: .password(username: parts[1], password: parts[2])
        )
        let serverID = record.id
        step("added the server \(serverID) (\(record.serverType ?? "?") \(record.serverVersion ?? "?"))")
        try expect(RemoteCredentialStore.shared.secret(for: serverID) != nil, "the secret is stored")

        let report = try await RemoteCatalogSync.shared.sync(serverID: serverID)
        let client = try await RemoteServers.shared.client(for: serverID)
        let expected = try await serverSongCount(client)
        let stored = try database.fetchRemoteTrackPaths(serverID: serverID)
        step("synced \(report.songs) songs; the server lists \(expected); the library holds \(stored.count)")
        try expect(stored.count == expected && expected > 0, "the song count equals the server's search3 count")

        await Library.shared.reloadFromDatabase()
        let remoteTracks = Library.shared.allTracks.filter { $0.remoteSong?.serverID == serverID }
        try expect(remoteTracks.count == expected, "the library model holds every remote song (\(remoteTracks.count))")
        guard let track = remoteTracks.sorted(by: { ($0.albumTitle, $0.trackNumber) < ($1.albumTitle, $1.trackNumber) })
            .first(where: { $0.codec == "FLAC" }), let song = track.remoteSong
        else { throw Failure(step: "the server has a FLAC song") }

        let playlist = try database.createPlaylist(name: "Remote exercise")
        let playlistID = try require(playlist.id, "the playlist has an id")
        try database.addTrackToPlaylist(playlistId: playlistID, trackFileURL: song.path)

        await RemoteStreamCache.shared.discardFiles(of: [song])
        try await playWithEqualizer(track, song: song)

        let fileURL = try await waitForCompleteFile(song)
        let original = try await client.download(id: song.songID)
        try expect(FileManager.default.contentsEqual(atPath: fileURL.path, andPath: original.path), "the cache file is byte-identical to the server's download")
        try? FileManager.default.removeItem(at: original)
        step("the cache file \(fileURL.lastPathComponent) matches the server's download")

        if let large = remoteTracks.first(where: { $0.codec == "WAV" })?.remoteSong {
            try await checkSeekAndNewVersion(large, client: client)
        } else {
            step("no WAV song on the server; skipped the seek and new-version steps")
        }
        try await pinAlbumAndCheck(containing: song, serverID: serverID)
        try await removeServerAndCheck(serverID: serverID, playlistID: playlistID)
        try? database.deletePlaylist(id: playlistID)
    }

    private static func playWithEqualizer(_ track: Track, song: RemoteTrackPath) async throws {
        let engine = EqualizerEngine.shared
        engine.start()
        engine.select(profileID: EqualizerPresets.id(forKey: "bassBoost"))
        try expect(engine.isRunning, "the equalizer runs a non-flat preset")
        let tapsBefore = engine.preparedTapCount
        AudioPlayer.shared.play([track], startingAt: 0)
        try await Task.sleep(for: .seconds(3))
        let position = AudioPlayer.shared.currentTime
        let context = EqualizerTapRegistry.shared.playingContext()
        let frames = context?.framesProcessed ?? 0
        let rate = context?.sampleRate ?? 0
        step("after 3 s: position \(position), taps before \(tapsBefore), prepared \(engine.preparedTapCount), frames \(frames) at \(rate) Hz, playing \(AudioPlayer.shared.isPlaying)")
        try expect(position > 1.5, "(a) the playback position advanced (\(position) s)")
        try expect(tapsBefore == 0 && frames > 0 && Double(frames) >= rate, "(b) the equalizer tap processed audio for the item (frames \(frames), prepared \(engine.preparedTapCount))")
        AudioPlayer.shared.togglePlayPause()
    }

    private static func waitForCompleteFile(_ song: RemoteTrackPath) async throws -> URL {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if let file = RemoteStreamCache.shared.completeFileURL(for: song) { return file }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw Failure(step: "the cache file became complete within 30 s")
    }

    private static func checkSeekAndNewVersion(_ song: RemoteTrackPath, client: SubsonicClient) async throws {
        let cache = RemoteStreamCache.shared
        let database = DatabaseManager.shared
        let original = try await client.download(id: song.songID)
        defer { try? FileManager.default.removeItem(at: original) }
        let whole = try Data(contentsOf: original)
        let total = Int64(whole.count)
        try expect(total > 3_200_000, "the large song is bigger than 3.2 MB (\(total))")

        await cache.discardFiles(of: [song])
        let window: Range<Int64> = 3_000_000..<3_100_000
        let demand = try await cache.beginDemand(song, range: window)
        var read = Data()
        var offset = window.lowerBound
        while offset < window.upperBound {
            let part = try await cache.read(song, from: offset, upTo: window.upperBound, maxLength: 64 * 1_024)
            read.append(part)
            offset += Int64(part.count)
        }
        await cache.endDemand(song, demand)
        try expect(read == whole[Int(window.lowerBound)..<Int(window.upperBound)], "a read in the middle of the file returns the server's bytes")
        try expect(cache.completeFileURL(for: song) == nil, "fetching the middle fetched only the middle, not the whole file")
        step("read \(read.count) bytes at offset \(window.lowerBound) of \(total) without fetching the rest")

        let before = try require(try database.fetchTrack(byRelativePath: song.path), "the large song has a row").revision
        try await cache.replaceValidatorForExercise(of: song, with: "Mon, 01 Jan 2001 00:00:00 GMT")
        try await cache.ensure(song, range: 1_000..<2_000)
        let bumped = try await waitForRevision(song, above: before)
        try expect(bumped, "a 200 to an If-Range request recorded a new version")
        let file = try await cache.downloadComplete(song)
        try expect(try Data(contentsOf: file) == whole, "after the reset the cache file is the server's bytes")
    }

    private static func waitForRevision(_ song: RemoteTrackPath, above revision: Int) async throws -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if (try DatabaseManager.shared.fetchTrack(byRelativePath: song.path))?.revision ?? 0 > revision { return true }
            try await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    private static func pinAlbumAndCheck(containing song: RemoteTrackPath, serverID: String) async throws {
        let database = DatabaseManager.shared
        let paths = try database.fetchRemoteAlbumPaths(containing: song.path)
        try expect(!paths.isEmpty, "the song's album has songs")
        for path in paths {
            guard let member = RemoteTrackPath(path: path) else { throw Failure(step: "the album path \(path) parses") }
            try await RemoteStreamCache.shared.downloadComplete(member, pinnedFor: .user)
        }
        let folder = RemoteCacheLayout.pinnedRoot().appendingPathComponent(song.escapedServerID, isDirectory: true)
        let audio = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { !$0.hasSuffix(RemoteCacheLayout.sidecarSuffix) }
        let pinnedRows = try database.fetchPinnedRemotePaths(serverID: serverID)
        step("pinned \(paths.count) album songs: \(audio.count) files under Application Support, \(pinnedRows.count) rows flagged")
        try expect(audio.count == paths.count, "every song of the pinned album has a file under Application Support")
        try expect(Set(pinnedRows) == Set(paths), "the pinned rows are the album's songs")
        let excluded = (try? folder.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup) ?? false
        try expect(excluded, "the pinned folder is excluded from backup")
        for path in paths {
            guard let member = RemoteTrackPath(path: path) else { continue }
            try expect(RemoteStreamCache.shared.completeFileURL(for: member)?.path.hasPrefix(RemoteCacheLayout.pinnedRoot().path) == true, "\(path) is whole and pinned")
        }
    }

    private static func removeServerAndCheck(serverID: String, playlistID: Int64) async throws {
        let database = DatabaseManager.shared
        let escaped = RemoteTrackPath(serverID: serverID, songID: "x").escapedServerID
        try await RemoteServers.shared.remove(id: serverID)
        let rows = try database.fetchRemoteTrackPaths(serverID: serverID)
        let places = try database.fetchPlaylistTracks(playlistId: playlistID).filter { RemoteTrackPath.isRemote($0.trackFileURL) }
        let cached = RemoteCacheLayout.cachesRoot().appendingPathComponent(escaped).path
        let pinned = RemoteCacheLayout.pinnedRoot().appendingPathComponent(escaped).path
        step("after removal: \(rows.count) rows, \(places.count) playlist places")
        try expect(rows.isEmpty, "the server's rows are gone")
        try expect(places.isEmpty, "the server's playlist rows are gone")
        try expect(!FileManager.default.fileExists(atPath: cached), "the cache folder is gone")
        try expect(!FileManager.default.fileExists(atPath: pinned), "the pinned folder is gone")
        try expect(try database.fetchRemoteServer(id: serverID) == nil, "the server row is gone")
        try expect(RemoteCredentialStore.shared.secret(for: serverID) == nil, "the secret is gone")
        try expect(!Library.shared.allTracks.contains { $0.remoteSong?.serverID == serverID }, "the library model holds none of its songs")
    }

    private static func serverSongCount(_ client: SubsonicClient) async throws -> Int {
        var count = 0
        var offset = 0
        while true {
            let page = try await client.songsPage(offset: offset, size: 500)
            if page.isEmpty { return count }
            count += page.count
            offset += page.count
        }
    }

    private static func expect(_ condition: Bool, _ step: String) throws {
        guard condition else { throw Failure(step: step) }
        RemoteLog.info("REMOTE EXERCISE PASS: \(step)")
    }

    private static func require<T>(_ value: T?, _ step: String) throws -> T {
        guard let value else { throw Failure(step: step) }
        return value
    }

    private static func step(_ text: String) {
        RemoteLog.info("REMOTE EXERCISE: \(text)")
    }
}
#endif
