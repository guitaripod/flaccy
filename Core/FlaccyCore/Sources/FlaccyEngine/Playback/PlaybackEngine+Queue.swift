import AVFoundation
import MidgarCore
import FlaccyCore

extension PlaybackEngine {

    /// Purges deleted files from the queue: keeps position when the playing
    /// track survives, advances to the nearest remaining track when it was
    /// deleted mid-play, and stops cleanly when nothing is left.
    public func handleDeletedTracks(_ urls: Set<URL>) {
        guard !queue.isEmpty, queue.contains(where: { urls.contains($0.fileURL) }) else { return }
        let playingURL = currentTrack?.fileURL
        let wasPlaying = isPlaying
        originalQueue.removeAll { urls.contains($0.fileURL) }
        var remaining = queue
        remaining.removeAll { urls.contains($0.fileURL) }

        if remaining.isEmpty {
            queue = []
            currentIndex = 0
            player?.pause()
            player?.removeAllItems()
            playingItem = nil
            preloadedItem = nil
            preloadedIndex = nil
            isPlaying = false
            host?.playbackStateDidUpdate()
            postOnMain(PlaybackEngine.trackDidChange)
            postOnMain(PlaybackEngine.playbackStateDidChange)
            postOnMain(PlaybackEngine.queueDidChange)
            return
        }

        if let playingURL, !urls.contains(playingURL) {
            queue = remaining
            currentIndex = remaining.firstIndex { $0.fileURL == playingURL } ?? 0
            resyncPreloadedItems()
        } else {
            let survivorsBefore = queue[..<currentIndex].filter { !urls.contains($0.fileURL) }.count
            queue = remaining
            currentIndex = min(survivorsBefore, remaining.count - 1)
            loadTrack(at: currentIndex)
            if !wasPlaying {
                userPausedPlayback = true
                player?.pause()
                isPlaying = false
                host?.playbackStateDidUpdate()
                postOnMain(PlaybackEngine.playbackStateDidChange)
            }
        }
        postOnMain(PlaybackEngine.queueDidChange)
    }

    public func toggleShuffle() {
        shuffleEnabled.toggle()
        host?.playFeedback(.light)

        if queue.count > 1 {
            let current = currentTrack
            if shuffleEnabled {
                originalQueue = queue
                var remaining = queue
                remaining.remove(at: currentIndex)
                remaining = historyAwareShuffle(remaining)
                if let current {
                    queue = [current] + remaining
                } else {
                    queue = remaining
                }
                currentIndex = 0
            } else {
                if let current, let idx = originalQueue.firstIndex(of: current) {
                    queue = originalQueue
                    currentIndex = idx
                } else {
                    queue = originalQueue
                    currentIndex = 0
                }
            }
        }

        resyncPreloadedItems()
        postOnMain(PlaybackEngine.shuffleRepeatDidChange)
        postOnMain(PlaybackEngine.queueDidChange)
    }

    public func cycleRepeatMode() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
        host?.playFeedback(.light)
        resyncPreloadedItems()
        postOnMain(PlaybackEngine.shuffleRepeatDidChange)
    }

    public func clearUpNext() {
        let firstUpcomingIndex = currentIndex + 1
        guard firstUpcomingIndex < queue.count else { return }
        let removed = Array(queue[firstUpcomingIndex...])
        queue.removeSubrange(firstUpcomingIndex...)
        for track in removed {
            if let origIdx = originalQueue.firstIndex(of: track) {
                originalQueue.remove(at: origIdx)
            }
        }
        resyncPreloadedItems()
        host?.playFeedback(.medium)
        postOnMain(PlaybackEngine.queueDidChange)
    }

    public func jumpToIndex(_ index: Int) {
        guard index >= 0, index < queue.count else { return }
        host?.trackWillBeSkipped()
        host?.playFeedback(.selection)
        loadTrack(at: index)
    }

    public func removeFromQueue(at index: Int) {
        guard index >= 0, index < queue.count, index != currentIndex else { return }
        let track = queue[index]
        queue.remove(at: index)
        if let origIdx = originalQueue.firstIndex(of: track) {
            originalQueue.remove(at: origIdx)
        }
        if index < currentIndex {
            currentIndex -= 1
        }
        resyncPreloadedItems()
        host?.playFeedback(.light)
        postOnMain(PlaybackEngine.queueDidChange)
    }

    public func moveInQueue(from sourceIndex: Int, to destinationIndex: Int) {
        guard sourceIndex >= 0, sourceIndex < queue.count,
              destinationIndex >= 0, destinationIndex < queue.count,
              sourceIndex != destinationIndex
        else { return }

        let playing = currentTrack
        let track = queue.remove(at: sourceIndex)
        queue.insert(track, at: destinationIndex)
        if let playing, let idx = queue.firstIndex(of: playing) {
            currentIndex = idx
        }

        resyncPreloadedItems()
        postOnMain(PlaybackEngine.queueDidChange)
    }

    public func insertNext(_ track: Track) {
        let wasEmpty = queue.isEmpty
        let insertIndex = min(currentIndex + 1, queue.count)
        queue.insert(track, at: insertIndex)
        if let current = currentTrack, let origIdx = originalQueue.firstIndex(of: current) {
            originalQueue.insert(track, at: min(origIdx + 1, originalQueue.count))
        } else {
            originalQueue.append(track)
        }
        resyncPreloadedItems()
        refreshDerivedContext()
        host?.playFeedback(.light)
        postOnMain(PlaybackEngine.queueDidChange)
        if wasEmpty {
            postOnMain(PlaybackEngine.trackDidChange)
        }
    }

    public func addToQueue(_ track: Track) {
        let wasEmpty = queue.isEmpty
        queue.append(track)
        originalQueue.append(track)
        resyncPreloadedItems()
        refreshDerivedContext()
        host?.playFeedback(.light)
        postOnMain(PlaybackEngine.queueDidChange)
        if wasEmpty {
            postOnMain(PlaybackEngine.trackDidChange)
        }
    }

    /// Shuffle that de-weights recently-played tracks using each track's `lastPlayed`
    /// timestamp, so a shuffle surfaces neglected music before recent repeats while
    /// still touching everything.
    func historyAwareShuffle(_ tracks: [Track]) -> [Track] {
        let weights = recencyWeights()
        return WeightedShuffle.shuffled(tracks) { weights[$0.fileURL.standardizedFileURL] ?? 1.0 }
    }

    func recencyWeights() -> [URL: Double] {
        guard let docs = host?.libraryRoot, let keys = try? DatabaseManager.shared.fetchTrackSortKeys() else { return [:] }
        let now = Date()
        let halfLife: Double = 3 * 24 * 3600
        var map: [URL: Double] = [:]
        for entry in keys {
            let url = RemoteTrackPath(path: entry.fileURL)?.assetURL ?? docs.appendingPathComponent(entry.fileURL).standardizedFileURL
            guard let lastPlayed = entry.lastPlayed else { map[url] = 1.0; continue }
            let age = max(0, now.timeIntervalSince(lastPlayed))
            map[url] = max(0.05, age / (age + halfLife))
        }
        return map
    }
}
