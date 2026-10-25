import MidgarCore
#if DEBUG
import FlaccyCore
import FlaccyEngine
import Foundation

/// The library a picture of the remote screens needs: the server named by `FLACCY_EXERCISE_REMOTE`
/// added as "Home Server", synced, with its first album downloaded. Launch with `--shot-remote <screen>`
/// (and `--skip-keychain` on an unsigned Mac build); the drivers log `REMOTE SHOT READY: <screen>`
/// when the screen is on display and `REMOTE SHOT FAILED: <why>` when the seed did not work.
@MainActor
enum RemoteShotSeed {

    static let argument = "--shot-remote"
    static let serverName = "Home Server"

    static var requestedScreen: String? {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: argument) else { return nil }
        return flag + 1 < arguments.count ? arguments[flag + 1] : "servers"
    }

    /// Adds, syncs and downloads; returns the server, or nil after logging why not.
    static func prepare() async -> RemoteServerRecord? {
        if CommandLine.arguments.contains("--skip-keychain") { RemoteCredentialStore.shared.useMemoryBackend() }
        try? await Task.sleep(for: .seconds(3))
        let parts = (ProcessInfo.processInfo.environment[RemoteExercise.environmentKey] ?? "").components(separatedBy: "|")
        guard parts.count == 3 else {
            fail("the environment variable \(RemoteExercise.environmentKey) holds url|user|password")
            return nil
        }
        do {
            let record = try await RemoteServers.shared.add(
                address: parts[0], name: serverName, authentication: .password(username: parts[1], password: parts[2])
            )
            try await RemoteCatalogSync.shared.sync(serverID: record.id)
            await Library.shared.reloadFromDatabase()
            let tracks = Library.shared.allTracks.filter { $0.remoteSong?.serverID == record.id }
            guard let first = tracks.min(by: { ($0.albumTitle, $0.trackNumber) < ($1.albumTitle, $1.trackNumber) }),
                  let firstSong = first.remoteSong
            else {
                fail("the server holds no songs")
                return nil
            }
            let paths = try DatabaseManager.shared.fetchRemoteAlbumPaths(containing: firstSong.path)
            let outcome = await RemoteDownloads.download(paths: paths) { _, _ in }
            MidgarLog.info("REMOTE SHOT: downloaded \(outcome.downloaded) of \(outcome.total) songs of \(first.albumTitle)", category: .content)
            await RemoteCatalogSync.shared.noteNewVersion(path: firstSong.path, size: nil)
            try? await Task.sleep(for: .seconds(1))
            return record
        } catch {
            fail(error.localizedDescription)
            return nil
        }
    }

    static func fail(_ reason: String) {
        MidgarLog.error("REMOTE SHOT FAILED: \(reason)", category: .content)
    }

    static func ready(_ screen: String) {
        MidgarLog.info("REMOTE SHOT READY: \(screen)", category: .content)
    }

    static var credentials: (address: String, username: String, password: String)? {
        let parts = (ProcessInfo.processInfo.environment[RemoteExercise.environmentKey] ?? "").components(separatedBy: "|")
        return parts.count == 3 ? (parts[0], parts[1], parts[2]) : nil
    }
}
#endif
