import FlaccyCore
import MidgarCore
import Foundation
import UIKit
import WatchConnectivity

/// iOS side of the watch sync bridge. The ledger in FlaccyCore is the only
/// record of what is on the watch and what is on its way; this class feeds it
/// events (the watch's heartbeat, transfer progress, failures), prepares songs
/// with `WatchTranscoder`, hands them to WatchConnectivity a few at a time, and
/// publishes the result to the screens.
final class WatchSyncService: NSObject {

    static let shared = WatchSyncService()
    static let stateDidChange = Notification.Name("WatchSyncStateDidChange")
    static let progressDidChange = Notification.Name("WatchSyncProgressDidChange")

    enum AlbumState: Equatable {
        case notSynced
        case partial(synced: Int, total: Int)
        case waiting
        case preparing
        case sending(Double)
        case synced
        case storageFull
        case failed
    }

    enum FitResult {
        case fits
        case tooLarge(needed: Int64, free: Int64)
        case unknown
    }

    private static let requestedKey = "watchSync.requestedPaths"
    private static let supersededKey = "watchSync.supersededPaths"
    private static let profileKey = "watchSync.audioProfile"
    private static let fitMargin: Int64 = 50 * 1_024 * 1_024
    private static let ackGrace: TimeInterval = 600

    var ledger: WatchSyncLedger
    let transcoder: WatchTranscoder
    let metrics = WatchSyncMetrics()

    private(set) var profile: WatchAudioProfile
    private(set) var watchUsedBytes: Int64 = 0
    private(set) var watchTotalBytes: Int64 = 0

    var hasHeartbeat = false
    var lastConfirmed: Set<String> = []
    var transfers: [String: WCSessionFileTransfer] = [:]
    var observations: [String: NSKeyValueObservation] = [:]
    var prepared: [String: WatchTranscoder.Prepared] = [:]
    var prepareTasks: [String: Task<Void, Never>] = [:]
    var preparingStems: Set<String> = []
    var bytesByStem: [String: Int64] = [:]
    var runStems: Set<String> = []
    var wakeTimer: Timer?
    var metricsTimer: Timer?
    var contextTimer: Timer?
    var latestJob: EnrichmentJobProgress?
    var latestBatch: SyncBatch = .idle
    var lastSentContext: [String: Data] = [:]
    var jobObserver: NSObjectProtocol?
    var libraryObserver: NSObjectProtocol?
    var revisionObserver: NSObjectProtocol?

    private var trackIndex: [String: Track]?
    private var stemCache: [URL: String] = [:]
    private var sizeCache: [String: Int64] = [:]

    override init() {
        let stored = UserDefaults.standard.stringArray(forKey: Self.requestedKey) ?? []
        let superseded = UserDefaults.standard.stringArray(forKey: Self.supersededKey) ?? []
        ledger = WatchSyncLedger(
            requested: Set(stored.map(SyncStem.of)),
            superseded: Set(superseded.map(SyncStem.of)),
            policy: WatchSyncLedger.Policy(ackGrace: Self.ackGrace)
        )
        profile = UserDefaults.standard.string(forKey: Self.profileKey)
            .flatMap(WatchAudioProfile.init(rawValue:)) ?? .standard
        transcoder = WatchTranscoder(cacheDirectory: Self.transcodeDirectory)
        super.init()
        observeEnrichmentJob()
        observeLibrary()
        observeRevisions()
        WatchSyncBackgroundTask.shared.onExpiration = { [weak self] in self?.suspendPreparation() }
    }

    private static var transcodeDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WatchTranscode", isDirectory: true)
    }

    var wcSession: WCSession? { WCSession.isSupported() ? WCSession.default : nil }

    var isSupported: Bool { WCSession.isSupported() }
    var isPaired: Bool { wcSession?.isPaired ?? false }
    var isWatchAppInstalled: Bool { wcSession?.isWatchAppInstalled ?? false }
    var isReachable: Bool { wcSession?.isReachable ?? false }
    var isActivated: Bool { wcSession?.activationState == .activated }

    func activate() {
        guard let wcSession else { return }
        wcSession.delegate = self
        wcSession.activate()
        MidgarLog.info("WCSession activate requested (iOS)", category: .connectivity)
    }

    var watchFreeBytes: Int64 { ledger.watchFreeBytes }
    var watchIsFull: Bool { ledger.watchIsFull }
    var syncedCount: Int { ledger.syncedCount }
    var requestedCount: Int { ledger.requested.count }
    var unconfirmedCount: Int { ledger.unconfirmedCount }
    var stuckCount: Int { ledger.stuckCount }
    var diskFullCount: Int { ledger.diskFullCount }
    var activeTransferCount: Int { ledger.inFlightCount + ledger.queuedCount }
    var preparingCount: Int { preparingStems.count }
    var isSyncing: Bool { ledger.inFlightCount > 0 || ledger.queuedCount > 0 }
    var speedBytesPerSec: Double { metrics.speedBytesPerSec }
    var etaSeconds: TimeInterval? { metrics.etaSeconds }

    var sessionTotalBytesPending: Int64 {
        runStems.reduce(0) { $0 + (bytesByStem[$1] ?? 0) }
    }

    var sessionTransferredBytes: Int64 {
        runStems.reduce(0) { total, stem in
            total + Int64(Double(bytesByStem[stem] ?? 0) * ledger.fraction(of: [stem]))
        }
    }

    var sessionFraction: Double {
        let pending = sessionTotalBytesPending
        return pending > 0 ? min(1, Double(sessionTransferredBytes) / Double(pending)) : 0
    }

    var activeBytesRemaining: Int64 {
        max(0, sessionTotalBytesPending - sessionTransferredBytes)
    }

    func setProfile(_ newProfile: WatchAudioProfile) {
        guard newProfile != profile else { return }
        profile = newProfile
        UserDefaults.standard.set(newProfile.rawValue, forKey: Self.profileKey)
        MidgarLog.info("Watch audio profile set to \(newProfile.rawValue)", category: .connectivity)
        notify()
    }

    func stem(of track: Track) -> String {
        if let cached = stemCache[track.fileURL] { return cached }
        let stem = SyncStem.of(relativePath(for: track.fileURL))
        stemCache[track.fileURL] = stem
        return stem
    }

    func track(forStem stem: String) -> Track? {
        if trackIndex == nil {
            trackIndex = Dictionary(
                Library.shared.allTracks.map { (self.stem(of: $0), $0) },
                uniquingKeysWith: { first, _ in first }
            )
        }
        return trackIndex?[stem]
    }

    func isSynced(_ track: Track) -> Bool { ledger.isOnWatch(stem(of: track)) }

    func isSyncing(_ track: Track) -> Bool {
        switch ledger.phase(of: stem(of: track)) {
        case .preparing?, .sending?: true
        default: false
        }
    }

    func isSyncing(album: Album) -> Bool { album.tracks.contains { isSyncing($0) } }

    func syncedCount(in album: Album) -> Int { album.tracks.filter { isSynced($0) }.count }

    func albumSyncFraction(_ album: Album) -> Double {
        ledger.fraction(of: album.tracks.map { stem(of: $0) })
    }

    func state(of album: Album) -> AlbumState {
        let phases = album.tracks.map { ledger.phase(of: stem(of: $0)) }
        let total = phases.count
        let synced = phases.filter { $0 == .onWatch }.count
        if phases.contains(.diskFull) { return .storageFull }
        if phases.contains(where: { if case .stuck? = $0 { true } else { false } }) { return .failed }
        if phases.contains(where: { if case .sending? = $0 { true } else { false } }) {
            return .sending(albumSyncFraction(album))
        }
        if phases.contains(.preparing) { return .preparing }
        if synced == total, total > 0 { return .synced }
        if phases.contains(where: { $0 != nil && $0 != .onWatch }) { return .waiting }
        return synced > 0 ? .partial(synced: synced, total: total) : .notSynced
    }

    func fileSize(of url: URL) -> Int64 {
        if let cached = sizeCache[url.path] { return cached }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        sizeCache[url.path] = size
        return size
    }

    func estimatedBytes(for track: Track) -> Int64 {
        WatchSyncSizing.estimatedBytes(for: track, profile: profile)
    }

    func totalBytes(in album: Album) -> Int64 {
        WatchSyncSizing.totalBytes(in: album, profile: profile)
    }

    func sourceBytes(in album: Album) -> Int64 {
        album.tracks.reduce(0) { $0 + WatchSyncSizing.sourceBytes($1) }
    }

    func fitResult(for album: Album) -> FitResult {
        guard watchFreeBytes > 0 else { return .unknown }
        let needed = album.tracks.reduce(Int64(0)) { sum, track in
            isSynced(track) ? sum : sum + estimatedBytes(for: track)
        }
        return needed + Self.fitMargin <= watchFreeBytes ? .fits : .tooLarge(needed: needed, free: watchFreeBytes)
    }

    @discardableResult
    func sync(tracks: [Track]) -> SendResult {
        let readiness = self.readiness
        guard readiness.canQueue else {
            MidgarLog.notice("Sync skipped: \(readiness)", category: .connectivity)
            return .notReady(readiness)
        }
        let pending = tracks.filter { !isSynced($0) }.count
        let items = tracks.map { (stem: stem(of: $0), bytes: estimatedBytes(for: $0)) }
        ledger.request(items, now: Date())
        for item in items {
            bytesByStem[item.stem] = item.bytes
            if !ledger.isOnWatch(item.stem) { runStems.insert(item.stem) }
        }
        persistRequested()
        startRun()
        pump()
        return pending == 0 ? .nothingToSend : .started(pending)
    }

    /// Cancels anything queued or in flight for the removed tracks before the
    /// remove command goes out; a file still on its way would otherwise land
    /// after the delete and bring the album back.
    @discardableResult
    func remove(tracks: [Track]) -> Bool {
        guard isActivated else { return false }
        let stems = tracks.map { stem(of: $0) }
        guard !stems.isEmpty else { return false }
        for stem in stems { discardWork(for: stem) }
        ledger.withdraw(stems)
        runStems.subtract(stems)
        persistRequested()
        sendCommand([SyncKeys.command: SyncKeys.commandRemove, SyncKeys.removePaths: stems])
        MidgarLog.info("Requested remove of \(stems.count) tracks", category: .connectivity)
        pump()
        return true
    }

    func removeAll() {
        releaseRemoteFiles(of: ledger.requested.compactMap { track(forStem: $0) })
        cancelAllWork()
        ledger.reset()
        persistRequested()
        sendCommand([SyncKeys.command: SyncKeys.commandRemoveAll])
        MidgarLog.info("Requested remove-all", category: .connectivity)
        endRunIfIdle()
        notify()
    }

    func retryStuck() {
        ledger.retryStuck(now: Date())
        pump()
    }

    func reconcile() {
        refreshRequestedFromLibrary()
        pump()
    }

    /// Picks the pipeline back up when the app comes to the foreground, for
    /// work a cancelled or expired background task left waiting in the queue.
    func resumeIfNeeded() {
        guard isActivated, !ledger.requested.isEmpty else { return }
        requestWatchState()
        pump()
    }

    func pump() {
        guard canPump else {
            notify()
            return
        }
        let now = Date()
        ledger.expireLostAcks(now: now)
        for stem in ledger.nextToStart(now: now) { begin(stem) }
        afterLedgerChange()
    }

    func afterLedgerChange() {
        armWakeTimer()
        endRunIfIdle()
        publishBatch()
        reportBackgroundProgress()
        notify()
    }

    func notify() {
        NotificationCenter.default.post(name: Self.stateDidChange, object: nil)
    }

    func notifyProgress() {
        NotificationCenter.default.post(name: Self.progressDidChange, object: nil)
    }

    func persistRequested() {
        UserDefaults.standard.set(ledger.requested.sorted(), forKey: Self.requestedKey)
        UserDefaults.standard.set(ledger.superseded.sorted(), forKey: Self.supersededKey)
    }

    func relativePath(for url: URL) -> String {
        if let song = RemoteTrackPath(assetURL: url) { return Self.watchPath(of: song) }
        let documents = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(documents) else { return canonicalSyncPath(url.lastPathComponent) }
        let relative = String(path.dropFirst(documents.count))
        return canonicalSyncPath(relative.hasPrefix("/") ? String(relative.dropFirst()) : relative)
    }

    /// Where a song from a server sits among the watch's files: one folder per server, the song's
    /// id as the name, the server's suffix as the extension so the watch knows what it was handed.
    private static func watchPath(of song: RemoteTrackPath) -> String {
        let suffix = RemoteSongDirectory.shared.source(for: song)?.suffix
        let name = suffix.map { "\(song.escapedSongID).\($0)" } ?? song.escapedSongID
        return "Remote/\(song.escapedServerID)/\(name)"
    }

    /// The file a song is prepared from. A song on a server is downloaded whole first and pinned
    /// for the watch, so the transcoder and the transfer read a file that will not be evicted.
    private static func sourceFile(of track: Track) async throws -> URL {
        guard let song = track.remoteSong else { return track.fileURL }
        return try await RemoteStreamCache.shared.downloadComplete(song, pinnedFor: .watch)
    }

    /// Lets go of the files of songs on servers that the watch no longer wants.
    private func releaseRemoteFiles(of tracks: [Track]) {
        let songs = tracks.compactMap(\.remoteSong)
        guard !songs.isEmpty else { return }
        Task {
            for song in songs { try? await RemoteStreamCache.shared.unpin(song, reason: .watch) }
        }
    }

    func applyHeartbeat(used: Int64, total: Int64) {
        watchUsedBytes = used
        watchTotalBytes = total
    }

    /// Whether the pipeline may hand work out: the session is live and the
    /// watch has either spoken or has never had anything to say, so a fresh
    /// install is not blocked waiting for a heartbeat that cannot come.
    private var canPump: Bool {
        guard let wcSession, wcSession.activationState == .activated, wcSession.isWatchAppInstalled else { return false }
        guard !ledger.watchIsFull else { return false }
        return hasHeartbeat || wcSession.receivedApplicationContext.isEmpty
    }

    private func begin(_ stem: String) {
        guard let track = track(forStem: stem) else {
            dropOrphan(stem)
            return
        }
        guard track.remoteSong != nil || FileManager.default.fileExists(atPath: track.fileURL.path) else {
            MidgarLog.error("Sync source missing, dropping request: \(stem)", category: .connectivity)
            dropOrphan(stem)
            return
        }
        preparingStems.insert(stem)
        let profile = profile
        prepareTasks[stem] = Task { [weak self] in
            guard let self else { return }
            do {
                let source = try await Self.sourceFile(of: track)
                let output = try await self.transcoder.prepare(source: source, profile: profile)
                self.finishPreparation(stem: stem, track: track, output: output)
            } catch is CancellationError {
                self.preparationEnded(stem)
            } catch {
                self.preparationFailed(stem: stem, error: error)
            }
        }
    }

    private func finishPreparation(stem: String, track: Track, output: WatchTranscoder.Prepared) {
        preparationEnded(stem)
        guard let wcSession, ledger.phase(of: stem) == .preparing else {
            Task { await transcoder.release(output) }
            return
        }
        bytesByStem[stem] = output.bytes
        ledger.updateBytes(stem: stem, bytes: output.bytes)
        prepared[stem] = output
        let destination = SyncStem.destinationPath(forSource: relativePath(for: track.fileURL), encoded: output.wasEncoded)
        let metadata = TransferMetadata(
            relativePath: destination,
            title: track.title,
            artist: track.artist,
            album: track.albumTitle,
            trackNumber: track.trackNumber,
            duration: track.duration,
            bytes: output.bytes
        )
        let transfer = wcSession.transferFile(output.url, metadata: metadata.dictionary)
        attach(transfer, stem: stem)
        ledger.markSending(stem: stem, fraction: transfer.progress.fractionCompleted)
        MidgarLog.info("Queued transfer: \(destination) (\(output.bytes) bytes\(output.wasEncoded ? ", encoded" : ""))", category: .connectivity)
        afterLedgerChange()
    }

    private func preparationFailed(stem: String, error: Error) {
        preparationEnded(stem)
        MidgarLog.error("Preparing \(stem) failed: \(error.localizedDescription)", category: .connectivity)
        ledger.markFailed(stem: stem, failure: .transient, now: Date())
        afterLedgerChange()
    }

    private func preparationEnded(_ stem: String) {
        preparingStems.remove(stem)
        prepareTasks[stem] = nil
    }

    private func dropOrphan(_ stem: String) {
        ledger.withdraw([stem])
        runStems.remove(stem)
        persistRequested()
        afterLedgerChange()
    }

    /// Withdraws requests whose track is gone from the library, but only once
    /// the library has something in it: an empty library at launch means
    /// "not loaded yet", and acting on it would forget everything requested.
    func refreshRequestedFromLibrary() {
        guard !Library.shared.allTracks.isEmpty else { return }
        var orphans: [String] = []
        for stem in ledger.requested {
            if let track = track(forStem: stem) {
                let bytes = estimatedBytes(for: track)
                bytesByStem[stem] = bytes
                ledger.updateBytes(stem: stem, bytes: bytes)
            } else {
                orphans.append(stem)
            }
        }
        guard !orphans.isEmpty else { return }
        for stem in orphans { discardWork(for: stem) }
        ledger.withdraw(orphans)
        persistRequested()
        MidgarLog.info("Dropped \(orphans.count) requested tracks no longer in the library", category: .connectivity)
    }

    func discardWork(for stem: String) {
        prepareTasks[stem]?.cancel()
        prepareTasks[stem] = nil
        preparingStems.remove(stem)
        if let track = track(forStem: stem) {
            let source = track.remoteSong.flatMap { RemoteStreamCache.shared.fileURL(for: $0) } ?? track.fileURL
            Task { await transcoder.cancel(source: source) }
            releaseRemoteFiles(of: [track])
        }
        transfers[stem]?.cancel()
        settle(stem)
    }

    /// Forgets the live handles for a stem: its observation, its transfer and
    /// the encoded file that was waiting to be delivered.
    func settle(_ stem: String) {
        observations[stem] = nil
        transfers[stem] = nil
        if let output = prepared.removeValue(forKey: stem) {
            Task { await transcoder.release(output) }
        }
    }

    func cancelAllWork() {
        for task in prepareTasks.values { task.cancel() }
        prepareTasks.removeAll()
        preparingStems.removeAll()
        wcSession?.outstandingFileTransfers.forEach { $0.cancel() }
        for stem in Array(prepared.keys) { settle(stem) }
        observations.removeAll()
        transfers.removeAll()
        runStems.removeAll()
        bytesByStem.removeAll()
        hasHeartbeat = false
        lastConfirmed = []
        wakeTimer?.invalidate()
        wakeTimer = nil
        stopMetrics()
    }

    /// Stops the work that needs this process to be running when the system or
    /// the person ends the background task; everything stays requested and is
    /// picked up again the next time the app is active.
    func suspendPreparation() {
        for stem in preparingStems {
            prepareTasks[stem]?.cancel()
            ledger.abandonPreparation(stem: stem)
        }
        prepareTasks.removeAll()
        preparingStems.removeAll()
        notify()
    }

    func resetForNoWatchApp() {
        cancelAllWork()
        ledger.reset()
        persistRequested()
        applyHeartbeat(used: 0, total: 0)
        endRunIfIdle()
        notify()
    }

    private func startRun() {
        guard !runStems.isEmpty else { return }
        if metricsTimer == nil {
            metrics.start(transferredBytes: sessionTransferredBytes, now: Date())
            metricsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.sampleMetrics() }
            }
        }
        WatchSyncBackgroundTask.shared.begin(total: runStems.count)
    }

    private func sampleMetrics() {
        guard !runStems.isEmpty else {
            stopMetrics()
            return
        }
        metrics.sample(transferredBytes: sessionTransferredBytes, remainingBytes: activeBytesRemaining, now: Date())
        notifyProgress()
    }

    private func stopMetrics() {
        metricsTimer?.invalidate()
        metricsTimer = nil
        metrics.reset()
    }

    func endRunIfIdle() {
        guard !runStems.isEmpty, !ledger.isBusy else { return }
        runStems.removeAll()
        stopMetrics()
        WatchSyncBackgroundTask.shared.finish()
    }

    private func reportBackgroundProgress() {
        let handedOff = runStems.filter { stem in
            switch ledger.phase(of: stem) {
            case .awaitingAck?, .onWatch?: true
            default: false
            }
        }.count
        WatchSyncBackgroundTask.shared.update(completed: handedOff, total: runStems.count)
    }

    private func armWakeTimer() {
        wakeTimer?.invalidate()
        wakeTimer = nil
        guard let wakeAt = ledger.nextWakeUp(now: Date()) else { return }
        let delay = max(1, wakeAt.timeIntervalSinceNow)
        wakeTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.pump() }
        }
    }

    private func observeLibrary() {
        libraryObserver = NotificationCenter.default.addObserver(
            forName: Library.didUpdateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.trackIndex = nil
                self?.stemCache.removeAll()
                self?.sizeCache.removeAll()
                WatchSyncSizing.invalidate()
                self?.refreshRequestedFromLibrary()
                self?.pump()
            }
        }
    }

    private func observeRevisions() {
        revisionObserver = NotificationCenter.default.addObserver(
            forName: Library.tracksRevised,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let paths = notification.userInfo?[Library.RevisionKey.paths] as? [String] ?? []
            MainActor.assumeIsolated { self?.supersede(paths: paths) }
        }
    }

    /// Sends the requested songs among `paths` to the watch again, since the
    /// copy it holds is of a version the phone has since replaced.
    func supersede(paths: [String]) {
        let stems = paths.map(SyncStem.of).filter { ledger.requested.contains($0) }
        guard !stems.isEmpty else { return }
        ledger.supersede(stems)
        for stem in stems where !ledger.isOnWatch(stem) { runStems.insert(stem) }
        sizeCache.removeAll()
        WatchSyncSizing.invalidate()
        persistRequested()
        MidgarLog.info("Sending \(stems.count) new versions to the watch", category: .connectivity)
        startRun()
        pump()
    }

    func publish(jobProgress: EnrichmentJobProgress) {
        guard jobProgress != latestJob else { return }
        latestJob = jobProgress
        scheduleContextPublish()
    }

    private func observeEnrichmentJob() {
        latestJob = EnrichmentCoordinator.shared.progress
        jobObserver = NotificationCenter.default.addObserver(
            forName: EnrichmentCoordinator.progressDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let progress = notification.userInfo?[EnrichmentCoordinator.ProgressKey.progress] as? EnrichmentJobProgress
            MainActor.assumeIsolated {
                self?.publish(jobProgress: progress ?? EnrichmentCoordinator.shared.progress)
            }
        }
    }
}
