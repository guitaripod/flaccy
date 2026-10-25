#if DEBUG && os(iOS)
import FlaccyCore
import FlaccyEngine
import Foundation

/// Drives the watch relay of songs on a server against a real server and a paired watch
/// simulator, and logs `WATCH REMOTE EXERCISE PASSED` or `WATCH REMOTE EXERCISE FAILED: <step>`.
/// Launch the phone with `--exercise-watch-remote --trial-day 2` and the environment variable
/// `FLACCY_EXERCISE_REMOTE=<url>|<user>|<password>` on a fresh simulator pair that has the app
/// and its watch app installed; add `--skip-keychain` when the keychain refuses the build.
///
/// It adds the server, syncs the catalog and relays two lossless songs: the one with the highest
/// bit rate, which the transcoder must encode, and the one with the lowest, which is already
/// leaner than the watch's target and must travel as the cached file itself. For each it checks
/// that the phone downloaded the whole song and pinned it for the watch without marking it as
/// the person's download, that the transcoder worked from that cached file, that the watch's
/// heartbeat reports the song, and that withdrawing it empties the watch and lets go of the pin.
/// Then it removes the server.
@MainActor
enum WatchRemoteExercise {

    static let launchArgument = "--exercise-watch-remote"

    private struct Failure: Error {
        let step: String
    }

    private struct Relay {
        let track: Track
        let song: RemoteTrackPath
        let sourceBytes: Int64
        let expectsEncode: Bool
    }

    static func runIfRequested() {
        guard CommandLine.arguments.contains(launchArgument) else { return }
        Task {
            var serverID: String?
            do {
                try await run(addedServer: &serverID)
                await cleanUp(serverID: serverID)
                RemoteLog.info("WATCH REMOTE EXERCISE PASSED")
            } catch let failure as Failure {
                await cleanUp(serverID: serverID)
                RemoteLog.error("WATCH REMOTE EXERCISE FAILED: \(failure.step)")
            } catch {
                await cleanUp(serverID: serverID)
                RemoteLog.error("WATCH REMOTE EXERCISE FAILED: \(error.localizedDescription)")
            }
        }
    }

    private static func run(addedServer serverID: inout String?) async throws {
        if CommandLine.arguments.contains("--skip-keychain") { RemoteCredentialStore.shared.useMemoryBackend() }
        #if targetEnvironment(simulator)
        WatchSyncService.simulatesDelivery = true
        #endif
        let service = WatchSyncService.shared
        try await waitFor(seconds: 120, "the watch app is installed and the session is active") {
            service.isActivated && service.isWatchAppInstalled
        }
        try await waitFor(seconds: 60, "the watch has reported what it holds") { service.hasHeartbeat }
        try await Task.sleep(for: .seconds(3))
        let parts = (ProcessInfo.processInfo.environment[RemoteExercise.environmentKey] ?? "").components(separatedBy: "|")
        try expect(parts.count == 3, "the environment variable \(RemoteExercise.environmentKey) holds url|user|password")

        let record = try await RemoteServers.shared.add(
            address: parts[0], name: "Watch Exercise", authentication: .password(username: parts[1], password: parts[2])
        )
        serverID = record.id
        let report = try await RemoteCatalogSync.shared.sync(serverID: record.id)
        step("added the server and synced \(report.songs) songs")
        await Library.shared.reloadFromDatabase()
        service.setProfile(.high)

        let relays = try chooseRelays(serverID: record.id)
        for relay in relays {
            try await relayAndWithdraw(relay, service: service, record: record)
        }
    }

    /// The lossless songs of the server by bit rate: the richest must be encoded, the leanest is
    /// below the profile's target and goes as it is.
    private static func chooseRelays(serverID: String) throws -> [Relay] {
        let ranked = Library.shared.allTracks
            .filter { $0.remoteSong?.serverID == serverID && SyncStem.kind(ofExtension: $0.audioExtension) == .lossless }
            .compactMap { track -> (track: Track, song: RemoteTrackPath, bytes: Int64, rate: Double)? in
                guard let song = track.remoteSong, track.duration > 0,
                      let bytes = RemoteSongDirectory.shared.source(for: song)?.size else { return nil }
                return (track, song, bytes, Double(bytes) / track.duration)
            }
            .sorted { $0.rate > $1.rate }
        let richest = try require(ranked.first, "the server has a lossless song")
        let leanest = try require(ranked.last, "the server has a lossless song")
        try expect(richest.song != leanest.song, "the server has two lossless songs of different bit rates")
        step("relaying \(richest.track.title) (encoded) and \(leanest.track.title) (as it is)")
        return [
            Relay(track: richest.track, song: richest.song, sourceBytes: richest.bytes, expectsEncode: true),
            Relay(track: leanest.track, song: leanest.song, sourceBytes: leanest.bytes, expectsEncode: false),
        ]
    }

    private static func relayAndWithdraw(_ relay: Relay, service: WatchSyncService, record: RemoteServerRecord) async throws {
        let label = relay.expectsEncode ? "encoded song" : "lean song"
        let cache = RemoteStreamCache.shared
        await cache.discardFiles(of: [relay.song])
        try expect(cache.completeFileURL(for: relay.song) == nil, "the \(label) starts with no file on the phone")
        let stem = service.stem(of: relay.track)
        try expect(stem.hasPrefix("Remote/") && !stem.contains("."), "the \(label) has a stem made of its folder and id")

        let baseline = service.watchUsedBytes
        let recorder = PreparedOutputRecorder(stem: stem, service: service)
        defer { recorder.stop() }
        let result = service.sync(tracks: [relay.track])
        try expect(result == .started(1), "the phone accepts the request for the \(label) (\(result))")
        try await waitFor(seconds: 300, "the watch's heartbeat reports the \(label)") { service.isSynced(relay.track) }

        let cached = try await checkPhoneDownloadedAndPinned(relay, record: record, label: label)
        try checkTranscoderWorkedFromCache(recorder.output, cached: cached, relay: relay, label: label)
        let gained = service.watchUsedBytes - baseline
        try expect(gained == recorder.output?.bytes, "the watch gained exactly the bytes the transcoder prepared for the \(label) (\(gained))")
        try expect(service.lastConfirmed.filter { $0.hasPrefix(stem) } == [stem], "the watch's inventory lists the \(label) once")
        try await checkWithdrawal(relay, service: service, stem: stem, baseline: baseline, label: label)
    }

    private static func checkPhoneDownloadedAndPinned(_ relay: Relay, record: RemoteServerRecord, label: String) async throws -> URL {
        let file = try require(RemoteStreamCache.shared.completeFileURL(for: relay.song), "the phone holds the whole \(label)")
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        try expect(size == relay.sourceBytes, "the phone's file of the \(label) is as long as the server's (\(size ?? -1))")
        try expect(file.path.hasPrefix(RemoteCacheLayout.pinnedRoot().path), "the \(label) is pinned under Application Support for the watch")
        let client = try await RemoteServers.shared.client(for: record.id)
        let original = try await client.download(id: relay.song.songID)
        defer { try? FileManager.default.removeItem(at: original) }
        try expect(FileManager.default.contentsEqual(atPath: file.path, andPath: original.path), "the pinned \(label) is byte-identical to the server's download")
        let flagged = try DatabaseManager.shared.fetchPinnedRemotePaths(serverID: record.id)
        try expect(!flagged.contains(relay.song.path), "the watch's pin does not mark the \(label) as the person's download")
        return file
    }

    private static func checkTranscoderWorkedFromCache(
        _ output: WatchTranscoder.Prepared?, cached: URL, relay: Relay, label: String
    ) throws {
        let output = try require(output, "the transcoder handed the service a file for the \(label)")
        if relay.expectsEncode {
            try expect(output.wasEncoded && output.destinationExtension == SyncStem.encodedExtension, "the transcoder encoded the cached \(label) to \(output.destinationExtension)")
            try expect(output.bytes > 0 && output.bytes < relay.sourceBytes, "the encode is smaller than the cached file (\(output.bytes) < \(relay.sourceBytes))")
            try expect(output.url.path.contains("WatchTranscode"), "the encode of the \(label) sits in the transcode cache")
        } else {
            try expect(!output.wasEncoded && output.bytes == relay.sourceBytes, "the transcoder left the \(label) as it is (\(output.bytes))")
            try expect(output.url.standardizedFileURL == cached.standardizedFileURL, "the file sent for the \(label) is the pinned cache file itself")
        }
    }

    private static func checkWithdrawal(
        _ relay: Relay, service: WatchSyncService, stem: String, baseline: Int64, label: String
    ) async throws {
        try expect(service.remove(tracks: [relay.track]), "the phone sends the removal of the \(label)")
        try await waitFor(seconds: 120, "the watch reports the \(label) gone") {
            !service.isSynced(relay.track) && !service.lastConfirmed.contains(stem)
        }
        try await waitFor(seconds: 30, "the phone lets go of the pin on the \(label)") {
            RemoteStreamCache.shared.completeFileURL(for: relay.song)?.path.hasPrefix(RemoteCacheLayout.cachesRoot().path) == true
        }
        try expect(service.watchUsedBytes == baseline, "the watch is back to the bytes it held before the \(label) (\(service.watchUsedBytes))")
        try expect(RemoteStreamCache.shared.completeFileURL(for: relay.song) != nil, "the whole \(label) stays on the phone as cache")
    }

    private static func cleanUp(serverID: String?) async {
        WatchSyncService.shared.setProfile(.standard)
        if let serverID { try? await RemoteServers.shared.remove(id: serverID) }
    }

    private static func waitFor(seconds: Int, _ step: String, _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<(seconds * 4) {
            if condition() {
                RemoteLog.info("WATCH REMOTE EXERCISE PASS: \(step)")
                return
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw Failure(step: step)
    }

    private static func expect(_ condition: Bool, _ step: String) throws {
        guard condition else { throw Failure(step: step) }
        RemoteLog.info("WATCH REMOTE EXERCISE PASS: \(step)")
    }

    private static func require<T>(_ value: T?, _ step: String) throws -> T {
        guard let value else { throw Failure(step: step) }
        return value
    }

    private static func step(_ text: String) {
        RemoteLog.info("WATCH REMOTE EXERCISE: \(text)")
    }
}

/// Remembers the file the transcoder prepared for one stem. The service holds it only until the
/// transfer is handed off, and publishes a state change as soon as it is stored, so listening to
/// that notification sees it before it goes.
@MainActor
private final class PreparedOutputRecorder {

    private(set) var output: WatchTranscoder.Prepared?
    private var observer: NSObjectProtocol?

    init(stem: String, service: WatchSyncService) {
        observer = NotificationCenter.default.addObserver(
            forName: WatchSyncService.stateDidChange, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                if self?.output == nil { self?.output = service.prepared[stem] }
            }
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }
}
#endif
