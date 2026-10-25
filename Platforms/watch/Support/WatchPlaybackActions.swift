import FlaccyCore

extension WatchAudioPlayer {

    /// Shuffles everything on the watch and starts from a random song.
    func shuffleAll(_ tracks: [MediaItem]) {
        guard !tracks.isEmpty else { return }
        if !shuffleEnabled { toggleShuffle() }
        play(tracks, startingAt: Int.random(in: tracks.indices))
    }

    /// Where the restored session stands, as the segmented progress draws it.
    var resumePoint: ResumePoint? {
        guard hasRestorableSession, !queue.isEmpty else { return nil }
        return ResumePoint(
            trackIndex: currentIndex,
            elapsed: pendingResumePosition ?? currentTime,
            durations: queue.map(\.duration),
            savedAt: .now
        )
    }
}
