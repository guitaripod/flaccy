import FlaccyCore
import Foundation

/// Keeps remote songs on this device on request: the Download and Remove Download entries of
/// every song, album and playlist menu go through here. A download is a pin the person asked
/// for, which lands the whole file outside the cache limit.
@MainActor
enum RemoteDownloads {

    /// What a menu's download entry should offer for some songs.
    enum MenuState: Equatable {
        case download
        case removeDownload
    }

    struct Outcome: Equatable {
        var total = 0
        var downloaded = 0
        var failureReason: String?
    }

    private static let parallelism = 3

    /// Nil when none of the paths is a song on a server, so the menu leaves the entry out.
    static func menuState(for paths: [String]) -> MenuState? {
        let remote = paths.filter(RemoteTrackPath.isRemote)
        guard !remote.isEmpty else { return nil }
        return remote.allSatisfy { RemoteAvailability.shared.isPinned(path: $0) } ? .removeDownload : .download
    }

    static func menuState(for tracks: [Track]) -> MenuState? {
        menuState(for: tracks.compactMap { $0.remoteSong?.path })
    }

    /// Downloads every remote song of `paths` that is not downloaded yet, three at a time,
    /// reporting how many are done after each one.
    static func download(paths: [String], progress: @escaping @MainActor (_ done: Int, _ total: Int) -> Void) async -> Outcome {
        let songs = paths.compactMap { RemoteTrackPath(path: $0) }
        var outcome = Outcome(total: songs.count)
        guard !songs.isEmpty else { return outcome }
        progress(0, songs.count)
        await withTaskGroup(of: String?.self) { group in
            var pending = songs.makeIterator()
            func addNext(_ group: inout TaskGroup<String?>) -> Bool {
                guard let song = pending.next() else { return false }
                group.addTask { await fetch(song) }
                return true
            }
            for _ in 0..<parallelism { _ = addNext(&group) }
            var finished = 0
            for await failure in group {
                finished += 1
                if let failure {
                    outcome.failureReason = outcome.failureReason ?? failure
                } else {
                    outcome.downloaded += 1
                }
                progress(finished, songs.count)
                _ = addNext(&group)
            }
        }
        RemoteLog.info("Downloaded \(outcome.downloaded) of \(outcome.total) songs")
        return outcome
    }

    /// Lets go of the downloads of `paths`: the files stay as cache until the space is needed.
    static func remove(paths: [String]) async -> Int {
        var removed = 0
        for path in paths {
            guard let song = RemoteTrackPath(path: path), RemoteAvailability.shared.isPinned(path: path) else { continue }
            do {
                try await RemoteStreamCache.shared.unpin(song, reason: .user)
                removed += 1
            } catch {
                RemoteLog.error("Could not remove the download of \(path): \(error.localizedDescription)")
            }
        }
        return removed
    }

    private nonisolated static func fetch(_ song: RemoteTrackPath) async -> String? {
        do {
            try await RemoteStreamCache.shared.downloadComplete(song, pinnedFor: .user)
            return nil
        } catch is CancellationError {
            return String(localized: "The download was interrupted. Try again.")
        } catch {
            let host = await RemoteServers.shared.displayHost(for: song.serverID)
            return RemoteFailure.from(error, host: host).errorDescription
        }
    }
}
