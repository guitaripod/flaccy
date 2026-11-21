#if DEBUG
import AVFoundation
import FlaccyCore
import FlaccyEngine
import Foundation

/// Plays three songs from a real server back to back and logs `REMOTE STREAM DRILL PASSED` or
/// `REMOTE STREAM DRILL FAILED: <step>`. Launch with `--exercise-remote-stream --trial-day 2` and
/// `FLACCY_EXERCISE_REMOTE=<url>|<user>|<password>`; add `--skip-keychain` on an unsigned Mac build.
///
/// Nothing is cached when it starts, so every song streams. Each of the first two songs is played for a few
/// seconds, moved to six seconds before its end and left to finish; the drill passes when the queue then reaches
/// the next song by itself, in order, and that song's position advances. Run it through a connection that cuts
/// every response short to prove a song survives the network dropping under it.
@MainActor
enum RemoteStreamDrill {

    static let launchArgument = "--exercise-remote-stream"

    private struct Failure: Error {
        let step: String
    }

    static func runIfRequested() {
        guard CommandLine.arguments.contains(launchArgument) else { return }
        Task {
            do {
                try await run()
                RemoteLog.info("REMOTE STREAM DRILL PASSED")
            } catch let failure as Failure {
                RemoteLog.error("REMOTE STREAM DRILL FAILED: \(failure.step)")
            } catch {
                RemoteLog.error("REMOTE STREAM DRILL FAILED: \(error.localizedDescription)")
            }
        }
    }

    private static func run() async throws {
        if CommandLine.arguments.contains("--skip-keychain") { RemoteCredentialStore.shared.useMemoryBackend() }
        try await Task.sleep(for: .seconds(3))
        let parts = (ProcessInfo.processInfo.environment[RemoteExercise.environmentKey] ?? "").components(separatedBy: "|")
        try expect(parts.count == 3, "the environment variable \(RemoteExercise.environmentKey) holds url|user|password")
        let record = try await RemoteServers.shared.add(
            address: parts[0], name: "Stream drill", authentication: .password(username: parts[1], password: parts[2])
        )
        let report = try await RemoteCatalogSync.shared.sync(serverID: record.id)
        await Library.shared.reloadFromDatabase()
        let tracks = Library.shared.allTracks
            .filter { $0.remoteSong?.serverID == record.id }
            .sorted { $0.title < $1.title }
        try expect(tracks.count >= 3, "the server has three songs (\(report.songs) synced)")
        let queue = Array(tracks.prefix(3))
        await RemoteStreamCache.shared.discardFiles(of: queue.compactMap(\.remoteSong))
        step("playing \(queue.map { "\($0.title) [\($0.codec ?? "?")]" }.joined(separator: ", "))")

        let player = AudioPlayer.shared
        #if os(macOS)
        player.volume = 0
        #endif
        player.play(queue, startingAt: 0)
        for index in 0..<2 {
            try await waitUntil(60, "song \(index) plays past 3 s") { player.currentIndex == index && player.currentTime > 3 }
            if ProcessInfo.processInfo.environment["FLACCY_DRILL_WHOLE"] != nil, let song = queue[index].remoteSong {
                try await waitUntil(120, "song \(index) is whole on disk") { RemoteStreamCache.shared.completeFileURL(for: song) != nil }
            }
            let length = player.duration
            try expect(length > 20, "song \(index) reports its length (\(length) s)")
            player.seek(to: length - 6)
            try await waitUntil(60, "song \(index) plays on after the seek to its last 6 s") {
                player.currentIndex != index || player.currentTime > length - 4
            }
            try await waitUntil(90, "the queue reaches song \(index + 1) by itself") { player.currentIndex != index }
            try expect(player.currentIndex == index + 1, "song \(index) hands over to song \(index + 1), not \(player.currentIndex)")
            try await waitUntil(60, "song \(index + 1) plays past 2 s after the handover") {
                player.currentIndex == index + 1 && player.isPlaying && player.currentTime > 2
            }
            step("song \(index) handed over to song \(index + 1), now at \(player.currentTime) s")
        }
        player.togglePlayPause()
        try await RemoteServers.shared.remove(id: record.id)
    }

    private static func waitUntil(_ seconds: TimeInterval, _ step: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() {
                RemoteLog.info("REMOTE STREAM DRILL PASS: \(step)")
                return
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw Failure(step: "\(step) within \(Int(seconds)) s")
    }

    private static func expect(_ condition: Bool, _ step: String) throws {
        guard condition else { throw Failure(step: step) }
        RemoteLog.info("REMOTE STREAM DRILL PASS: \(step)")
    }

    private static func step(_ text: String) {
        RemoteLog.info("REMOTE STREAM DRILL: \(text)")
    }
}
#endif
