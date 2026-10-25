import FlaccyCore
import Foundation

extension AudioPlayer {

    /// Tells the server a song of theirs started, and points the cache at what plays now and next:
    /// the rest of this song and the first 2 MB of the one behind it are fetched, and neither
    /// file may be evicted while it is wanted.
    func reportRemoteStart(of track: Track) {
        if let song = track.remoteSong { RemoteServerReports.started(song) }
        let upcoming = queue.indices.contains(currentIndex + 1) ? queue[currentIndex + 1].remoteSong : nil
        let current = track.remoteSong
        Task {
            await RemoteStreamCache.shared.protect(current: current, next: upcoming)
            await RemoteStreamCache.shared.prefetch(current: current, next: upcoming)
        }
    }
}
