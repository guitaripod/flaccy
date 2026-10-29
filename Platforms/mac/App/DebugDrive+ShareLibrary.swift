import MidgarCore
#if DEBUG
import AppKit
import FlaccyCore
import FlaccyEngine
import FlaccyServerEmbed
import Foundation

/// `--exercise-share-mac <folder>` turns on "Share this Mac's library" against a folder of generated songs and logs
/// `MAC SHARE EXERCISE PASSED` or `MAC SHARE EXERCISE FAILED: <step>`. The folder is taken as the library folder through its
/// security-scoped bookmark, so the server reads it the way it reads a chosen one. The exercise waits for the server, for this Mac to
/// enroll itself over loopback, makes a playlist and a love, syncs, and asks the server over HTTP with the device token. It writes
/// `Caches/share-drive.json` with the port so a second machine can reach the server. Add `--skip-keychain` for an ad-hoc signed
/// build and `--share-shots` for the pictures of `DebugShareLibraryShots`. `--share-quit-after <seconds>` quits the app through the
/// ordinary quit path afterwards, which stops the server first. `--shot-share-mac-intro` clicks the real switch, answers
/// the first-run sheet and clicks it off again, with pictures, against the container's own library folder.
enum DebugShareLibraryDrive {

    static let argument = "--exercise-share-mac"
    static let introArgument = "--shot-share-mac-intro"
    static let quitArgument = "--share-quit-after"
    static let playlistName = "Road Trip"

    private struct Failure: Error {
        let step: String
    }

    static func runIfRequested(window: NSWindow?) {
        if CommandLine.arguments.contains(introArgument) {
            if CommandLine.arguments.contains("--skip-keychain") { RemoteCredentialStore.shared.useMemoryBackend() }
            Task { await DebugShareLibraryShots.runIntro() }
        }
        guard let folder = DebugDrive.value(after: argument) else { return }
        if CommandLine.arguments.contains("--skip-keychain") { RemoteCredentialStore.shared.useMemoryBackend() }
        Task {
            do {
                try await run(folder: URL(filePath: folder, directoryHint: .isDirectory))
                MidgarLog.info("MAC SHARE EXERCISE PASSED", category: .sync)
                if CommandLine.arguments.contains("--share-shots") { await DebugShareLibraryShots.run(window: window) }
                if let seconds = DebugDrive.value(after: quitArgument).flatMap(Double.init) {
                    try? await Task.sleep(for: .seconds(seconds))
                    MidgarLog.info("MAC SHARE EXERCISE: quitting the app", category: .sync)
                    NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0.1)
                }
            } catch let failure as Failure {
                MidgarLog.error("MAC SHARE EXERCISE FAILED: \(failure.step)", category: .sync)
            } catch {
                MidgarLog.error("MAC SHARE EXERCISE FAILED: \(error.localizedDescription)", category: .sync)
            }
        }
    }

    private static func run(folder: URL) async throws {
        let sharing = MacLibrarySharing.shared
        let songs = flacCount(in: folder)
        try expect(songs > 0, "the folder holds songs (\(songs))")
        step("the throwaway folder holds \(songs) songs")
        try LibraryRoot.shared.chooseFolder(folder)
        step("the folder is the library folder, held through a security-scoped bookmark")
        try await wait("the library scanned the songs") { ((try? DatabaseManager.shared.fetchAllTracks()) ?? []).filter { $0.remoteServer == nil }.count >= songs }
        step("the library holds \(songs) songs")

        sharing.setEnabled(true)
        try await wait("the server started sharing \(songs) songs") {
            if case .sharing(let state) = sharing.state { return state.songCount == songs }
            return false
        }
        guard case .sharing(let state) = sharing.state, let loopback = state.addresses.loopbackURL else { throw Failure(step: "no loopback address") }
        step("sharing \(songs) songs on \(state.name), port \(state.addresses.port), tailnet \(state.reachesTailnet ? "reachable" : "absent")")

        let engine = ServerSyncService.engine
        try await wait("this Mac enrolled itself and synced") {
            guard engine.connectedServer?.url == loopback else { return false }
            if case .upToDate = FlaccyServerStatusStore.shared.status { return true }
            return false
        }
        step("this Mac is a device of its own server and is up to date")
        try expect(!(ServerSyncService.deviceToken(for: loopback) ?? "").isEmpty, "the device token is stored")
        try expect(FlaccyServerLibrary.record() == nil, "the library is not added a second time as a remote one")

        let loved = try makePlaylistAndLove()
        step("made the playlist \(playlistName) and loved a song")
        _ = await engine.syncNow()
        try await wait("the changes reached the server") { await engine.pendingChangeCount() == 0 }
        try await checkServer(loopback: loopback, loved: loved, songs: songs)
        try writeDriveFile(state: state)
        try await checkWakeRecovery(loopback: loopback)
    }

    private static func checkWakeRecovery(loopback: URL) async throws {
        try FlaccyServerHost().stop()
        let hello = loopback.appending(path: "flaccy/v1/hello")
        try expect((try? await get(hello, token: nil)) == nil, "the stopped server no longer answers")
        step("stopped the server behind the app's back; it does not answer")
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: NSWorkspace.shared)
        try await wait("the server answered again after the wake") { (try? await get(hello, token: nil)) != nil }
        guard case .sharing(let state) = MacLibrarySharing.shared.state else { throw Failure(step: "not sharing after the wake") }
        try expect(state.addresses.loopbackURL == loopback, "the server came back on the same port (\(state.addresses.port))")
        step("after the wake the server answers again on the same port \(state.addresses.port)")
    }

    private static func makePlaylistAndLove() throws -> String {
        let database = DatabaseManager.shared
        let tracks = try database.fetchAllTracks().filter { $0.remoteServer == nil }.sorted { $0.fileURL < $1.fileURL }
        guard let first = tracks.first else { throw Failure(step: "no song to love") }
        let playlist = try database.createPlaylist(name: playlistName)
        guard let id = playlist.id else { throw Failure(step: "the playlist has no id") }
        try database.addTracksToPlaylist(playlistId: id, trackFileURLs: tracks.prefix(2).map(\.fileURL))
        try database.setLoved(fileURL: first.fileURL, loved: true, pendingOp: nil)
        return first.fileURL
    }

    private static func checkServer(loopback: URL, loved: String, songs: Int) async throws {
        let hello = try await get(loopback.appending(path: "flaccy/v1/hello"), token: nil)
        let server = hello["server"] as? [String: Any]
        try expect(server?["name"] is String, "hello names the server")
        try expect((hello["features"] as? [String])?.contains("sync") == true, "hello lists sync")
        step("GET /hello answered \(server?["name"] as? String ?? "?")")
        guard let token = ServerSyncService.deviceToken(for: loopback) else { throw Failure(step: "no device token") }
        let signedIn = try await get(loopback.appending(path: "flaccy/v1/hello"), token: token)
        try expect((signedIn["caller"] as? [String: Any])?["device"] is String, "hello knows this device by its token")
        let pull = try await get(loopback.appending(path: "flaccy/v1/sync/pull").appending(queryItems: [URLQueryItem(name: "since", value: "0"), URLQueryItem(name: "limit", value: "1000")]), token: token)
        let changes = pull["changes"] as? [[String: Any]] ?? []
        let playlists = changes.filter { $0["kind"] as? String == "playlist" && !($0["deleted"] as? Bool ?? true) }
        let names = playlists.compactMap { ($0["value"] as? [String: Any])?["name"] as? String }
        try expect(names.contains(playlistName), "the server holds the playlist (\(names))")
        let entries = changes.filter { $0["kind"] as? String == "playlist_entry" && !($0["deleted"] as? Bool ?? true) }
        try expect(entries.count == 2, "the server holds both entries (\(entries.count))")
        let loves = changes.filter { $0["kind"] as? String == "love" && ($0["value"] as? [String: Any])?["loved"] as? Bool == true }
        try expect(loves.count == 1, "the server holds the love (\(loves.count))")
        step("GET /sync/pull with the device token holds the playlist, its \(entries.count) entries and \(loves.count) love")
        try await wait("the server counts this Mac as a device") {
            MacLibrarySharing.shared.refresh()
            if case .sharing(let state) = MacLibrarySharing.shared.state { return state.deviceCount >= 1 && state.songCount == songs }
            return false
        }
        step("the server counts a device and \(songs) songs")
    }

    private static func get(_ url: URL, token: String?) async throws -> [String: Any] {
        var request = URLRequest(url: url, timeoutInterval: 10)
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        try expect(status == 200, "\(url.path) answered \(status)")
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure(step: "\(url.path) did not answer JSON") }
        return object
    }

    private static func writeDriveFile(state: LibrarySharing.Sharing) throws {
        let document: [String: Any] = [
            "port": Int(state.addresses.port), "tailnet": state.addresses.tailnetHosts, "name": state.name, "songs": state.songCount ?? 0,
        ]
        try JSONSerialization.data(withJSONObject: document).write(to: URL.cachesDirectory.appending(path: "share-drive.json"), options: .atomic)
        step("wrote share-drive.json")
    }

    static func wait(_ what: String, seconds: Int = 90, _ condition: @MainActor () async -> Bool) async throws {
        for _ in 0..<(seconds * 4) {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(250))
        }
        throw Failure(step: "timed out waiting: \(what)")
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(step: message) }
    }

    private static func step(_ message: String) {
        MidgarLog.info("MAC SHARE EXERCISE: \(message)", category: .sync)
    }

    private static func flacCount(in folder: URL) -> Int {
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
        return files.filter { $0.pathExtension.lowercased() == "flac" }.count
    }
}
#endif
