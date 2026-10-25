import FlaccyCore
import FlaccyEngine
import Foundation

/// Why a song's file is being kept on the device: because the person pinned it, or because the watch asked for it.
nonisolated enum RemotePinReason: Hashable, Sendable {
    case user
    case watch
}

/// Holds the bytes of remote songs on disk, fetching only what is asked for.
///
/// Each song has one audio file and one sidecar listing which byte ranges of it are present.
/// Playback, prefetching and downloads all register a demand for some bytes; one fetch per song
/// runs at a time, serves the newest and most urgent demand first, and writes every chunk
/// to the file as it arrives so a reader can start before the download ends. Requests for the
/// same bytes share the fetch. A demand that ends stops the fetch nobody else needs.
actor RemoteStreamCache {

    static let shared = RemoteStreamCache()

    static let capKey = "flaccy.remote.cacheCapBytes"
    static let prefetchHeadBytes: Int64 = 2 * 1_024 * 1_024
    private static let sidecarWriteInterval: TimeInterval = 1
    private static let resumeSlackBytes: Int64 = 256 * 1_024

    /// The size the cache may grow to before the least recently used songs are removed; pinned songs are outside it.
    nonisolated static var capBytes: Int64 {
        get { (UserDefaults.standard.object(forKey: capKey) as? NSNumber)?.int64Value ?? RemoteCachePolicy.defaultCapBytes }
        set { UserDefaults.standard.set(newValue, forKey: capKey) }
    }

    nonisolated let cachesRoot: URL
    nonisolated let pinnedRoot: URL

    private enum Priority: Int, Comparable {
        case prefetch = 0
        case bulk = 1
        case playback = 2

        static func < (lhs: Priority, rhs: Priority) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    private struct Demand {
        let priority: Priority
        let range: Range<Int64>
        let order: Int
    }

    private enum WaitTarget {
        case range(Range<Int64>)
        case complete
    }

    private struct Waiter {
        let target: WaitTarget
        let continuation: CheckedContinuation<Void, Error>
    }

    private struct FetchTarget {
        let start: Int64
        let end: Int64?
    }

    private final class Entry {
        let song: RemoteTrackPath
        var audioURL: URL
        var sidecarURL: URL
        var sidecar: RemoteCacheSidecar
        var isPinned: Bool
        var pinReasons: Set<RemotePinReason> = []
        var handle: FileHandle?
        var demands: [UUID: Demand] = [:]
        var demandCounter = 0
        var waiters: [UUID: Waiter] = [:]
        var fetchTask: Task<Void, Never>?
        var activeStream: RemoteByteStream?
        var streamStopRequested = false
        var fetchCursor: Int64?
        var lastSidecarWrite = Date.distantPast
        var lastError: Error?

        init(song: RemoteTrackPath, audioURL: URL, sidecarURL: URL, sidecar: RemoteCacheSidecar, isPinned: Bool) {
            self.song = song
            self.audioURL = audioURL
            self.sidecarURL = sidecarURL
            self.sidecar = sidecar
            self.isPinned = isPinned
        }
    }

    private var entries: [String: Entry] = [:]
    private var prefetchDemands: [String: UUID] = [:]
    private var protectedKeys: Set<String> = []

    init(cachesRoot: URL = RemoteCacheLayout.cachesRoot(), pinnedRoot: URL = RemoteCacheLayout.pinnedRoot()) {
        self.cachesRoot = cachesRoot
        self.pinnedRoot = pinnedRoot
    }

    nonisolated func completeFileURL(for song: RemoteTrackPath) -> URL? {
        for root in [pinnedRoot, cachesRoot] {
            let sidecarURL = RemoteCacheLayout.sidecarURL(in: root, song: song)
            guard let data = try? Data(contentsOf: sidecarURL),
                  let sidecar = try? RemoteCacheSidecar.decode(data),
                  sidecar.isComplete, let total = sidecar.total
            else { continue }
            let audioURL = RemoteCacheLayout.directory(in: root, song: song).appendingPathComponent(sidecar.file)
            let size = (try? audioURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
            if size == total { return audioURL }
        }
        return nil
    }

    /// The file a feature that reads audio from disk may open for a track's URL: the file itself,
    /// the cached copy of a song on a server once it is whole, or nil while it is only streamed.
    nonisolated func readableFile(for url: URL) -> URL? {
        guard let song = RemoteTrackPath(assetURL: url) else { return url.isFileURL ? url : nil }
        return completeFileURL(for: song)
    }

    nonisolated func fileURL(for song: RemoteTrackPath) -> URL? {
        let suffix = RemoteSongDirectory.shared.source(for: song)?.suffix
        for root in [pinnedRoot, cachesRoot] {
            let sidecarURL = RemoteCacheLayout.sidecarURL(in: root, song: song)
            if FileManager.default.fileExists(atPath: sidecarURL.path) {
                return RemoteCacheLayout.audioURL(in: root, song: song, suffix: suffix)
            }
        }
        return nil
    }

    /// The length of the whole file, from the sidecar or the library row, or from the first response when neither knows.
    func totalBytes(of song: RemoteTrackPath) async throws -> Int64 {
        let entry = try entry(for: song)
        if let total = entry.sidecar.total { return total }
        let demand = try beginDemand(song, range: 0..<1, priority: .playback)
        defer { endDemand(song, demand) }
        try await wait(entry, for: .range(0..<1))
        guard let total = entry.sidecar.total else { throw RemoteFailure.songMissing }
        return total
    }

    nonisolated func suffix(of song: RemoteTrackPath) -> String? {
        RemoteSongDirectory.shared.source(for: song)?.suffix
    }

    /// Registers interest in `range` of a song and starts fetching it. The returned id ends it again.
    func beginDemand(_ song: RemoteTrackPath, range: Range<Int64>) throws -> UUID {
        try beginDemand(song, range: range, priority: .playback)
    }

    func endDemand(_ song: RemoteTrackPath, _ id: UUID) {
        guard let entry = entries[song.path], entry.demands.removeValue(forKey: id) != nil else { return }
        guard entry.activeStream != nil else { return }
        if let target = nextTarget(entry), let cursor = entry.fetchCursor, continues(from: cursor, at: target.start) {
            return
        }
        stopActiveStream(entry)
    }

    /// The next bytes of a song from `offset`, at most `maxLength` and never past `end`, waiting for them to arrive.
    func read(_ song: RemoteTrackPath, from offset: Int64, upTo end: Int64, maxLength: Int) async throws -> Data {
        let entry = try entry(for: song)
        touch(entry)
        while true {
            try Task.checkCancellation()
            let available = contiguousBytes(entry, from: offset, upTo: end)
            if available > 0 {
                return try readBytes(entry, from: offset, count: Int(min(available, Int64(maxLength))))
            }
            startFetchIfNeeded(entry)
            try await wait(entry, for: .range(offset..<(offset + 1)))
        }
    }

    /// Makes sure every byte of `range` is on disk, fetching what is missing with `Range` and `If-Range`.
    func ensure(_ song: RemoteTrackPath, range: Range<Int64>) async throws {
        let entry = try entry(for: song)
        let demand = try beginDemand(song, range: range, priority: .bulk)
        defer { endDemand(song, demand) }
        try await wait(entry, for: .range(range))
    }

    /// Downloads a whole song and returns its file. A reason pins it first, so it lands where it is never evicted.
    @discardableResult
    func downloadComplete(_ song: RemoteTrackPath, pinnedFor reason: RemotePinReason? = nil) async throws -> URL {
        if let reason { try await pin(song, reason: reason) }
        let entry = try entry(for: song)
        let demand = try beginDemand(song, range: 0..<Int64.max, priority: .bulk)
        defer { endDemand(song, demand) }
        try await wait(entry, for: .complete)
        evictIfNeeded()
        return entry.audioURL
    }

    func pin(_ song: RemoteTrackPath, reason: RemotePinReason) async throws {
        let entry = try entry(for: song)
        entry.pinReasons.insert(reason)
        if reason == .user { markPinned(song, true) }
        try await relocate(entry, toPinned: true)
    }

    func unpin(_ song: RemoteTrackPath, reason: RemotePinReason) async throws {
        let entry = try entry(for: song)
        entry.pinReasons.remove(reason)
        if reason == .user { markPinned(song, false) }
        let stillWanted = !entry.pinReasons.isEmpty || (RemoteSongDirectory.shared.source(for: song)?.pinned ?? false)
        if !stillWanted { try await relocate(entry, toPinned: false) }
    }

    /// Tells the cache which songs must keep their file: the one playing and the one preloaded behind it.
    func protect(current: RemoteTrackPath?, next: RemoteTrackPath?) {
        protectedKeys = Set([current, next].compactMap { $0.map(RemoteCacheLayout.key(for:)) })
    }

    /// Fetches the rest of the playing song and the first 2 MB of the next one, behind anything playback itself asks for.
    func prefetch(current: RemoteTrackPath?, next: RemoteTrackPath?) {
        var wanted: [String: (RemoteTrackPath, Range<Int64>)] = [:]
        if let current, completeFileURL(for: current) == nil { wanted[current.path] = (current, 0..<Int64.max) }
        if let next, next != current, completeFileURL(for: next) == nil {
            wanted[next.path] = (next, 0..<Self.prefetchHeadBytes)
        }
        for (path, id) in prefetchDemands where wanted[path] == nil {
            if let song = RemoteTrackPath(path: path) { endDemand(song, id) }
            prefetchDemands[path] = nil
        }
        for (path, request) in wanted where prefetchDemands[path] == nil {
            if let id = try? beginDemand(request.0, range: request.1, priority: .prefetch) { prefetchDemands[path] = id }
        }
    }

    /// Removes every file of a server, cached or pinned, and stops whatever is fetching them.
    func removeAll(serverID: String) {
        for (path, entry) in entries where entry.song.serverID == serverID {
            drop(entry, failingWaitersWith: CancellationError())
            entries[path] = nil
        }
        let folder = RemoteTrackPath(serverID: serverID, songID: "x").escapedServerID
        for root in [cachesRoot, pinnedRoot] {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(folder, isDirectory: true))
        }
        RemoteSongDirectory.shared.invalidateAll()
        RemoteAvailability.shared.forget(serverID: serverID)
    }

    /// Deletes the least recently used cached songs until the cache fits its cap again.
    func evictIfNeeded() {
        var busy = protectedKeys
        for entry in entries.values where !entry.demands.isEmpty || entry.fetchTask != nil {
            busy.insert(RemoteCacheLayout.key(for: entry.song))
        }
        let victims = RemoteCachePolicy.victims(
            entries: cachedEntries(), capBytes: Self.capBytes, protected: busy
        )
        for key in victims {
            guard let song = RemoteTrackPath(path: RemoteTrackPath.scheme + key) else { continue }
            if let entry = entries.removeValue(forKey: song.path) { drop(entry, failingWaitersWith: CancellationError()) }
            Self.removeFiles(of: song, in: cachesRoot)
            RemoteAvailability.shared.setComplete(song.path, false)
            RemoteLog.info("Cache evicted \(key)")
        }
    }

    /// Deletes the files of songs whose bytes changed or that left the library, cached or pinned.
    func discardFiles(of songs: [RemoteTrackPath]) {
        for song in songs {
            if let entry = entries.removeValue(forKey: song.path) { drop(entry, failingWaitersWith: CancellationError()) }
            Self.removeFiles(of: song, in: cachesRoot)
            Self.removeFiles(of: song, in: pinnedRoot)
            RemoteAvailability.shared.setComplete(song.path, false)
        }
    }

    /// Drops the files of songs the server now serves differently, and downloads the ones the
    /// person had downloaded again, so a download never stays flagged with no file behind it.
    func replaceFilesOfNewVersions(_ songs: [RemoteTrackPath]) {
        discardFiles(of: songs)
        redownloadPinned(songs)
    }

    /// Starts a whole download, one at a time per song, for every song in `songs` that the person keeps.
    func redownloadPinned(_ songs: [RemoteTrackPath]) {
        for song in songs where RemoteSongDirectory.shared.source(for: song)?.pinned == true {
            Task {
                do {
                    try await self.downloadComplete(song, pinnedFor: .user)
                    RemoteLog.info("Downloaded the new version of \(song.path) again")
                } catch is CancellationError {
                } catch {
                    RemoteLog.error("Could not download the new version of \(song.path): \(error.localizedDescription)")
                }
            }
        }
    }

    /// Deletes every cached song that nothing is reading or fetching. Downloads stay.
    @discardableResult
    func clearCache() -> Int64 {
        var busy = protectedKeys
        for entry in entries.values where !entry.demands.isEmpty || entry.fetchTask != nil {
            busy.insert(RemoteCacheLayout.key(for: entry.song))
        }
        var freed: Int64 = 0
        for item in cachedEntries() where !busy.contains(item.key) {
            guard let song = RemoteTrackPath(path: RemoteTrackPath.scheme + item.key) else { continue }
            if let entry = entries.removeValue(forKey: song.path) { drop(entry, failingWaitersWith: CancellationError()) }
            Self.removeFiles(of: song, in: cachesRoot)
            RemoteAvailability.shared.setComplete(song.path, false)
            freed += item.bytes
        }
        RemoteLog.info("Cache cleared: \(freed) bytes")
        return freed
    }

    nonisolated private static func removeFiles(of song: RemoteTrackPath, in root: URL) {
        let sidecarURL = RemoteCacheLayout.sidecarURL(in: root, song: song)
        if let data = try? Data(contentsOf: sidecarURL), let sidecar = try? RemoteCacheSidecar.decode(data) {
            try? FileManager.default.removeItem(at: RemoteCacheLayout.directory(in: root, song: song).appendingPathComponent(sidecar.file))
        }
        try? FileManager.default.removeItem(at: sidecarURL)
    }

    #if DEBUG
    /// Replaces the validator a song's cached bytes were fetched under, so a drive can make the
    /// server answer the next `If-Range` request as if the file had changed.
    func replaceValidatorForExercise(of song: RemoteTrackPath, with validator: String) throws {
        let entry = try entry(for: song)
        entry.sidecar.validator = validator
    }
    #endif

    /// The bytes the cache holds for unpinned songs, for a screen that shows the cache's size.
    nonisolated func cachedBytes() -> Int64 {
        cachedEntries().reduce(0) { $0 + $1.bytes }
    }

    /// The bytes of the songs kept outside the cache limit: downloaded by the person or held for the watch.
    nonisolated func downloadedBytes() -> Int64 {
        let manager = FileManager.default
        guard let servers = try? manager.contentsOfDirectory(at: pinnedRoot, includingPropertiesForKeys: nil) else { return 0 }
        var total: Int64 = 0
        for server in servers {
            let files = (try? manager.contentsOfDirectory(at: server, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.lastPathComponent.hasSuffix(RemoteCacheLayout.sidecarSuffix) {
                guard let data = try? Data(contentsOf: file), let sidecar = try? RemoteCacheSidecar.decode(data) else { continue }
                total += sidecar.ranges.coveredBytes
            }
        }
        return total
    }

    private func beginDemand(_ song: RemoteTrackPath, range: Range<Int64>, priority: Priority) throws -> UUID {
        let entry = try entry(for: song)
        entry.demandCounter += 1
        let id = UUID()
        entry.demands[id] = Demand(priority: priority, range: range, order: entry.demandCounter)
        touch(entry)
        startFetchIfNeeded(entry)
        return id
    }
}

extension RemoteStreamCache {

    private func entry(for song: RemoteTrackPath) throws -> Entry {
        if let known = entries[song.path] { return known }
        guard let source = RemoteSongDirectory.shared.source(for: song) else { throw RemoteFailure.songMissing }
        let entry = loadEntry(for: song, source: source)
        entries[song.path] = entry
        return entry
    }

    private func loadEntry(for song: RemoteTrackPath, source: RemoteSongSource) -> Entry {
        for (root, isPinned) in [(pinnedRoot, true), (cachesRoot, false)] {
            let sidecarURL = RemoteCacheLayout.sidecarURL(in: root, song: song)
            guard let data = try? Data(contentsOf: sidecarURL), var sidecar = try? RemoteCacheSidecar.decode(data) else { continue }
            let audioURL = RemoteCacheLayout.directory(in: root, song: song).appendingPathComponent(sidecar.file)
            Self.dropRangesThatLostTheirBytes(&sidecar, audioURL: audioURL)
            return Entry(song: song, audioURL: audioURL, sidecarURL: sidecarURL, sidecar: sidecar, isPinned: isPinned)
        }
        let root = source.pinned ? pinnedRoot : cachesRoot
        let fileName = RemoteCacheLayout.audioFileName(for: song, suffix: source.suffix)
        let sidecar = RemoteCacheSidecar(file: fileName, total: source.size, lastUsed: Date())
        return Entry(
            song: song,
            audioURL: RemoteCacheLayout.directory(in: root, song: song).appendingPathComponent(fileName),
            sidecarURL: RemoteCacheLayout.sidecarURL(in: root, song: song),
            sidecar: sidecar,
            isPinned: source.pinned
        )
    }

    /// A sidecar that outlived its file, or claims more bytes than the file holds, starts over.
    private static func dropRangesThatLostTheirBytes(_ sidecar: inout RemoteCacheSidecar, audioURL: URL) {
        let size = (try? audioURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let claimed = sidecar.ranges.ranges.map(\.upperBound).max() ?? 0
        if claimed > size { sidecar.ranges = ByteRangeSet() }
    }

    private func touch(_ entry: Entry) {
        entry.sidecar.lastUsedDate = Date()
    }

    private func markPinned(_ song: RemoteTrackPath, _ pinned: Bool) {
        try? DatabaseManager.shared.setRemotePinned(paths: [song.path], pinned: pinned)
        RemoteSongDirectory.shared.invalidate(paths: [song.path])
        RemoteAvailability.shared.setPinned([song.path], pinned)
    }

    private func openHandle(_ entry: Entry) throws -> FileHandle {
        if let handle = entry.handle { return handle }
        do {
            let directory = entry.audioURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if entry.isPinned { Self.excludeFromBackup(directory) }
            if !FileManager.default.fileExists(atPath: entry.audioURL.path) {
                FileManager.default.createFile(atPath: entry.audioURL.path, contents: nil)
            }
            let handle = try FileHandle(forUpdating: entry.audioURL)
            entry.handle = handle
            return handle
        } catch {
            throw RemoteFailure.storage
        }
    }

    private static func excludeFromBackup(_ directory: URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var folder = directory
        try? folder.setResourceValues(values)
        var parent = directory.deletingLastPathComponent()
        try? parent.setResourceValues(values)
    }

    private func closeHandle(_ entry: Entry) {
        try? entry.handle?.close()
        entry.handle = nil
    }

    private func write(_ chunk: Data, at offset: Int64, to entry: Entry) throws {
        let handle = try openHandle(entry)
        do {
            try handle.seek(toOffset: UInt64(offset))
            try handle.write(contentsOf: chunk)
        } catch {
            throw RemoteFailure.storage
        }
        entry.sidecar.ranges.insert(offset..<(offset + Int64(chunk.count)))
    }

    private func readBytes(_ entry: Entry, from offset: Int64, count: Int) throws -> Data {
        let handle = try openHandle(entry)
        do {
            try handle.seek(toOffset: UInt64(offset))
            return try handle.read(upToCount: count) ?? Data()
        } catch {
            throw RemoteFailure.storage
        }
    }

    private func contiguousBytes(_ entry: Entry, from offset: Int64, upTo end: Int64) -> Int64 {
        guard let range = entry.sidecar.ranges.ranges.first(where: { $0.contains(offset) }) else { return 0 }
        return min(range.upperBound, end) - offset
    }

    private func persist(_ entry: Entry) {
        guard entries[entry.song.path] === entry else { return }
        do {
            try FileManager.default.createDirectory(at: entry.sidecarURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try entry.sidecar.encoded().write(to: entry.sidecarURL, options: .atomic)
            entry.lastSidecarWrite = Date()
        } catch {
            RemoteLog.error("Could not write the cache sidecar of \(entry.song.path): \(error.localizedDescription)")
        }
    }

    private func persistIfDue(_ entry: Entry) {
        if Date().timeIntervalSince(entry.lastSidecarWrite) >= Self.sidecarWriteInterval { persist(entry) }
    }

    nonisolated private func cachedEntries() -> [RemoteCachePolicy.Entry] {
        let manager = FileManager.default
        guard let servers = try? manager.contentsOfDirectory(at: cachesRoot, includingPropertiesForKeys: nil) else { return [] }
        var result: [RemoteCachePolicy.Entry] = []
        for server in servers {
            let files = (try? manager.contentsOfDirectory(at: server, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.lastPathComponent.hasSuffix(RemoteCacheLayout.sidecarSuffix) {
                guard let data = try? Data(contentsOf: file), let sidecar = try? RemoteCacheSidecar.decode(data) else { continue }
                let song = String(file.lastPathComponent.dropLast(RemoteCacheLayout.sidecarSuffix.count))
                result.append(RemoteCachePolicy.Entry(
                    key: server.lastPathComponent + "/" + song,
                    bytes: sidecar.ranges.coveredBytes,
                    lastUsed: sidecar.lastUsedDate,
                    pinned: false
                ))
            }
        }
        return result
    }

    private func relocate(_ entry: Entry, toPinned pinned: Bool) async throws {
        guard entry.isPinned != pinned else { return }
        stopActiveStream(entry)
        let running = entry.fetchTask
        running?.cancel()
        await running?.value
        guard entries[entry.song.path] === entry, entry.isPinned != pinned else { return }
        closeHandle(entry)
        let root = pinned ? pinnedRoot : cachesRoot
        let destinationAudio = RemoteCacheLayout.directory(in: root, song: entry.song).appendingPathComponent(entry.sidecar.file)
        let destinationSidecar = RemoteCacheLayout.sidecarURL(in: root, song: entry.song)
        do {
            try FileManager.default.createDirectory(at: destinationAudio.deletingLastPathComponent(), withIntermediateDirectories: true)
            if pinned { Self.excludeFromBackup(destinationAudio.deletingLastPathComponent()) }
            try Self.move(entry.audioURL, to: destinationAudio)
            persistSidecar(entry.sidecar, at: destinationSidecar)
            try? FileManager.default.removeItem(at: entry.sidecarURL)
        } catch {
            throw RemoteFailure.storage
        }
        entry.audioURL = destinationAudio
        entry.sidecarURL = destinationSidecar
        entry.isPinned = pinned
        if !entry.demands.isEmpty { startFetchIfNeeded(entry) }
    }

    private static func move(_ source: URL, to destination: URL) throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: source.path) else { return }
        try? manager.removeItem(at: destination)
        try manager.moveItem(at: source, to: destination)
    }

    private func persistSidecar(_ sidecar: RemoteCacheSidecar, at url: URL) {
        try? sidecar.encoded().write(to: url, options: .atomic)
    }

    private func drop(_ entry: Entry, failingWaitersWith error: Error) {
        stopActiveStream(entry)
        entry.fetchTask?.cancel()
        entry.demands.removeAll()
        let waiters = entry.waiters
        entry.waiters.removeAll()
        for waiter in waiters.values { waiter.continuation.resume(throwing: error) }
        closeHandle(entry)
    }
}

extension RemoteStreamCache {

    private func isSatisfied(_ entry: Entry, _ target: WaitTarget) -> Bool {
        switch target {
        case .range(let range):
            guard let total = entry.sidecar.total else { return entry.sidecar.ranges.contains(range) }
            let wanted = range.lowerBound..<max(range.lowerBound, min(range.upperBound, total))
            return entry.sidecar.ranges.contains(wanted)
        case .complete:
            return entry.sidecar.isComplete
        }
    }

    private func wait(_ entry: Entry, for target: WaitTarget) async throws {
        if isSatisfied(entry, target) { return }
        startFetchIfNeeded(entry)
        let id = UUID()
        let path = entry.song.path
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                entry.waiters[id] = Waiter(target: target, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancelWaiter(path: path, id: id) }
        }
    }

    private func cancelWaiter(path: String, id: UUID) {
        guard let waiter = entries[path]?.waiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func resumeSatisfiedWaiters(_ entry: Entry) {
        for (id, waiter) in entry.waiters where isSatisfied(entry, waiter.target) {
            entry.waiters[id] = nil
            waiter.continuation.resume()
        }
    }

    private func failWaiters(_ entry: Entry, with error: Error) {
        let waiters = entry.waiters
        entry.waiters.removeAll()
        for waiter in waiters.values { waiter.continuation.resume(throwing: error) }
    }

    private func nextTarget(_ entry: Entry) -> FetchTarget? {
        let ordered = entry.demands.values.sorted { ($0.priority, $0.order) > ($1.priority, $1.order) }
        for demand in ordered {
            var range = demand.range
            if let total = entry.sidecar.total {
                range = range.lowerBound..<min(range.upperBound, max(total, range.lowerBound))
            }
            guard !range.isEmpty, let gap = entry.sidecar.ranges.missing(in: range).first else { continue }
            return FetchTarget(start: gap.lowerBound, end: gap.upperBound == Int64.max ? nil : gap.upperBound)
        }
        return nil
    }

    private func startFetchIfNeeded(_ entry: Entry) {
        guard entry.fetchTask == nil, nextTarget(entry) != nil else { return }
        entry.lastError = nil
        entry.fetchTask = Task { await self.runFetches(entry) }
    }

    private func stopActiveStream(_ entry: Entry) {
        guard let stream = entry.activeStream else { return }
        entry.streamStopRequested = true
        stream.cancel()
    }

    private func runFetches(_ entry: Entry) async {
        while !Task.isCancelled, entries[entry.song.path] === entry {
            guard let target = nextTarget(entry) else { break }
            do {
                try await fetch(entry, target)
            } catch is CancellationError {
                break
            } catch {
                entry.lastError = error
                noteReachability(after: error, entry: entry)
                failWaiters(entry, with: error)
                RemoteLog.error("Fetching \(entry.song.path) failed: \(error.localizedDescription)")
                break
            }
        }
        persist(entry)
        resumeSatisfiedWaiters(entry)
        entry.fetchTask = nil
        if entry.sidecar.isComplete {
            closeHandle(entry)
            RemoteAvailability.shared.setComplete(entry.song.path, true)
            evictIfNeeded()
        }
    }

    private func fetch(_ entry: Entry, _ target: FetchTarget) async throws {
        let client = try await RemoteServers.shared.client(for: entry.song.serverID)
        let host = client.host
        let sentValidator = entry.sidecar.validator
        let stream = try await client.openStream(
            id: entry.song.songID,
            range: RemoteStreamRange(start: target.start, end: target.end),
            validator: sentValidator
        )
        RemoteAvailability.shared.setReachable(serverID: entry.song.serverID, true)
        entry.activeStream = stream
        entry.streamStopRequested = false
        defer {
            stream.cancel()
            entry.activeStream = nil
            entry.fetchCursor = nil
        }
        var cursor = try adopt(stream.head, target: target, sentValidator: sentValidator, entry: entry, host: host)
        entry.fetchCursor = cursor
        var wroteAny = false
        do {
            for try await chunk in stream.chunks {
                guard entries[entry.song.path] === entry, !Task.isCancelled else { return }
                try write(chunk, at: cursor, to: entry)
                cursor += Int64(chunk.count)
                entry.fetchCursor = cursor
                wroteAny = true
                resumeSatisfiedWaiters(entry)
                persistIfDue(entry)
                if let end = target.end, cursor >= end { return }
                if shouldStop(entry, cursor: cursor) { return }
            }
        } catch {
            if entry.streamStopRequested || Task.isCancelled { return }
            throw RemoteFailure.from(error, host: host)
        }
        if !wroteAny, !entry.streamStopRequested { throw RemoteFailure.unreachable(host: host) }
    }

    private func noteReachability(after error: Error, entry: Entry) {
        switch error as? RemoteFailure {
        case .unreachable, .tlsFailure:
            RemoteAvailability.shared.setReachable(serverID: entry.song.serverID, false)
            if entry.demands.values.contains(where: { $0.priority == .playback }), !entry.sidecar.isComplete {
                RemoteAvailability.shared.announceUnavailable(entry.song)
            }
        default: break
        }
    }

    private func shouldStop(_ entry: Entry, cursor: Int64) -> Bool {
        guard let target = nextTarget(entry) else { return true }
        return !continues(from: cursor, at: target.start)
    }

    /// Whether a fetch that has written up to `cursor` reaches `start` soon enough to keep going rather than reopen.
    private func continues(from cursor: Int64, at start: Int64) -> Bool {
        start >= cursor && start - cursor <= Self.resumeSlackBytes
    }

    /// Reads what the response says about the file and returns where its body starts. A file that
    /// the server now serves differently, told by a 200 to an `If-Range` request or by another
    /// length, starts the cache over and records the new version.
    private func adopt(
        _ head: RemoteStreamHead, target: FetchTarget, sentValidator: String?, entry: Entry, host: String
    ) throws -> Int64 {
        switch head.statusCode {
        case 206:
            guard head.rangeStart == target.start else { throw RemoteFailure.httpStatus(206, host: host) }
            if let total = head.totalBytes, let known = entry.sidecar.total, total != known {
                try startOver(entry, total: total, validator: head.validator)
            } else {
                entry.sidecar.total = head.totalBytes ?? entry.sidecar.total
                entry.sidecar.validator = entry.sidecar.validator ?? head.validator
            }
            return target.start
        case 200:
            let lengthChanged = head.contentLength != nil && entry.sidecar.total != nil && head.contentLength != entry.sidecar.total
            if sentValidator != nil || lengthChanged {
                try startOver(entry, total: head.contentLength, validator: head.validator)
            } else {
                entry.sidecar.total = head.contentLength ?? entry.sidecar.total
                entry.sidecar.validator = entry.sidecar.validator ?? head.validator
            }
            return 0
        default:
            throw RemoteFailure.httpStatus(head.statusCode, host: host)
        }
    }

    private func startOver(_ entry: Entry, total: Int64?, validator: String?) throws {
        let handle = try openHandle(entry)
        do {
            try handle.truncate(atOffset: 0)
        } catch {
            throw RemoteFailure.storage
        }
        entry.sidecar.ranges = ByteRangeSet()
        entry.sidecar.total = total
        entry.sidecar.validator = validator
        persist(entry)
        let path = entry.song.path
        RemoteAvailability.shared.setComplete(path, false)
        RemoteLog.info("The server now serves different bytes for \(path); the cached copy was dropped")
        let song = entry.song
        let keptByPerson = entry.isPinned && (RemoteSongDirectory.shared.source(for: song)?.pinned ?? false)
        Task {
            await RemoteCatalogSync.shared.noteNewVersion(path: path, size: total)
            if keptByPerson { self.redownloadPinned([song]) }
        }
    }
}
