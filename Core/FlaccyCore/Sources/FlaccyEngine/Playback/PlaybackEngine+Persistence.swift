import AVFoundation
import MidgarCore
import FlaccyCore

extension PlaybackEngine {

    public func saveQueueState() {
        guard !(isRestoringQueue && queue.isEmpty) else { return }
        guard let docsDir = host?.libraryRoot else { return }
        let paths = queue.map { relativePath(for: $0, docsDir: docsDir) }
        UserDefaults.standard.set(paths, forKey: "flaccy.queue.paths")
        if shuffleEnabled {
            let originalPaths = originalQueue.map { relativePath(for: $0, docsDir: docsDir) }
            UserDefaults.standard.set(originalPaths, forKey: "flaccy.queue.originalPaths")
        } else {
            UserDefaults.standard.removeObject(forKey: "flaccy.queue.originalPaths")
        }
        UserDefaults.standard.set(currentIndex, forKey: "flaccy.queue.index")
        if paths.indices.contains(currentIndex) {
            UserDefaults.standard.set(paths[currentIndex], forKey: "flaccy.queue.currentPath")
        } else {
            UserDefaults.standard.removeObject(forKey: "flaccy.queue.currentPath")
        }
        UserDefaults.standard.set(currentTime, forKey: "flaccy.queue.elapsed")
        UserDefaults.standard.set(shuffleEnabled, forKey: "flaccy.queue.shuffle")
        saveContext()
        UserDefaults.standard.set(repeatMode == .all ? 1 : repeatMode == .one ? 2 : 0, forKey: "flaccy.queue.repeat")
    }

    func relativePath(for track: Track, docsDir: URL) -> String {
        let trackPath = track.fileURL.standardizedFileURL.path
        let docsPath = docsDir.path
        if trackPath.hasPrefix(docsPath) {
            let rel = String(trackPath.dropFirst(docsPath.count))
            return rel.hasPrefix("/") ? String(rel.dropFirst()) : rel
        }
        return track.fileURL.lastPathComponent
    }

    /// Reads the persisted queue keys synchronously, then resolves the saved
    /// paths into records off the main actor before hydrating tracks and
    /// rebuilding the paused player, so restoring a long queue never stalls
    /// launch with per-track database reads.
    public func restoreQueueState() {
        guard let paths = UserDefaults.standard.stringArray(forKey: "flaccy.queue.paths"),
              !paths.isEmpty else { return }

        let savedIndex = UserDefaults.standard.integer(forKey: "flaccy.queue.index")
        let savedElapsed = UserDefaults.standard.double(forKey: "flaccy.queue.elapsed")
        let savedShuffle = UserDefaults.standard.bool(forKey: "flaccy.queue.shuffle")
        let savedRepeat = UserDefaults.standard.integer(forKey: "flaccy.queue.repeat")
        let savedCurrentPath = UserDefaults.standard.string(forKey: "flaccy.queue.currentPath")
        let savedContext = Self.loadSavedContext()
        let savedOriginalPaths = savedShuffle
            ? UserDefaults.standard.stringArray(forKey: "flaccy.queue.originalPaths")
            : nil

        isRestoringQueue = true
        Task { [weak self] in
            let fetched = await Task.detached {
                Self.fetchRestorableRecords(paths: paths, originalPaths: savedOriginalPaths)
            }.value
            defer { self?.isRestoringQueue = false }
            self?.applyRestoredQueue(
                records: fetched.records,
                originalRecords: fetched.originalRecords,
                savedIndex: savedIndex,
                savedElapsed: savedElapsed,
                savedShuffle: savedShuffle,
                savedRepeat: savedRepeat,
                savedCurrentPath: savedCurrentPath
            )
            self?.applyRestoredContext(savedContext)
        }
    }

    nonisolated static func fetchRestorableRecords(
        paths: [String], originalPaths: [String]?
    ) -> (records: [(path: String, record: TrackRecord)], originalRecords: [TrackRecord]?) {
        let records = paths.compactMap { path -> (path: String, record: TrackRecord)? in
            guard let record = try? DatabaseManager.shared.fetchTrack(byRelativePath: path) else { return nil }
            return (path, record)
        }
        let originalRecords = originalPaths?.compactMap {
            try? DatabaseManager.shared.fetchTrack(byRelativePath: $0)
        }
        return (records, originalRecords)
    }

    func applyRestoredQueue(
        records: [(path: String, record: TrackRecord)],
        originalRecords: [TrackRecord]?,
        savedIndex: Int,
        savedElapsed: Double,
        savedShuffle: Bool,
        savedRepeat: Int,
        savedCurrentPath: String?
    ) {
        guard queue.isEmpty, playingItem == nil, let host else { return }

        var artworkByAlbum: [String: PlatformImage?] = [:]
        var restoredTracks: [Track] = []
        var restoredPaths: [String] = []
        for (path, record) in records {
            restoredTracks.append(host.restoredTrack(from: record, artworkByAlbum: &artworkByAlbum))
            restoredPaths.append(path)
        }

        guard !restoredTracks.isEmpty else { return }

        queue = restoredTracks
        if let originalRecords, !originalRecords.isEmpty {
            originalQueue = originalRecords.map { host.restoredTrack(from: $0, artworkByAlbum: &artworkByAlbum) }
        } else {
            originalQueue = restoredTracks
        }

        let resumeElapsed: Double
        if let savedCurrentPath, let idx = restoredPaths.firstIndex(of: savedCurrentPath) {
            currentIndex = idx
            resumeElapsed = savedElapsed
        } else if savedCurrentPath != nil {
            currentIndex = 0
            resumeElapsed = 0
        } else {
            currentIndex = min(max(savedIndex, 0), restoredTracks.count - 1)
            resumeElapsed = savedElapsed
        }

        shuffleEnabled = savedShuffle
        repeatMode = savedRepeat == 1 ? .all : savedRepeat == 2 ? .one : .off

        rebuildPlayerPaused(at: resumeElapsed)
        if let track = currentTrack {
            host.artworkIsNeeded(for: track)
        }

        postOnMain(PlaybackEngine.trackDidChange)
        postOnMain(PlaybackEngine.playbackStateDidChange)
        postOnMain(PlaybackEngine.queueDidChange)
        postOnMain(PlaybackEngine.shuffleRepeatDidChange)

        MidgarLog.info("Restored queue: \(restoredTracks.count) tracks, index \(currentIndex), elapsed \(resumeElapsed)s", category: .content)
    }
}
