import FlaccyCore
import Foundation
import WatchConnectivity

/// iOS side of the watch sync bridge: stages and transfers track files to the
/// paired Apple Watch over WatchConnectivity, measures throughput / ETA, tracks
/// per-file progress, and reconciles what the watch holds from its acks.
final class WatchSyncService: NSObject {

    static let shared = WatchSyncService()
    static let stateDidChange = Notification.Name("WatchSyncStateDidChange")
    static let progressDidChange = Notification.Name("WatchSyncProgressDidChange")

    private(set) var syncedPaths: Set<String> = []
    private(set) var progressByPath: [String: Double] = [:]
    private(set) var failedPaths: Set<String> = []
    private var observations: [String: NSKeyValueObservation] = [:]

    private var transferBytes: [String: Int64] = [:]
    private var cumulativeBytes: Int64 = 0
    private var sessionTotalBytes: Int64 = 0
    private(set) var speedBytesPerSec: Double = 0
    private(set) var etaSeconds: TimeInterval?
    private var metricsTimer: Timer?
    private var lastSampleBytes: Int64 = 0
    private var lastSampleTime: Date?
    private var sizeCache: [String: Int64] = [:]

    private let requestedKey = "watchSync.requestedPaths"
    private(set) var requestedPaths: Set<String> = []
    private var retryCounts: [String: Int] = [:]
    private(set) var stuckPaths: Set<String> = []
    private let maxRetries = 6

    private(set) var watchFreeBytes: Int64 = 0
    private(set) var watchIsFull: Bool = false
    private(set) var diskFullPaths: Set<String> = []
    private var awaitingConfirmation: [String: Date] = [:]
    private let confirmationSafetyValve: TimeInterval = 86_400
    private let confirmationHeartbeatSlack: TimeInterval = 10

    override init() {
        super.init()
        requestedPaths = Set(UserDefaults.standard.stringArray(forKey: requestedKey) ?? [])
    }

    private var wcSession: WCSession? { WCSession.isSupported() ? WCSession.default : nil }

    var isSupported: Bool { WCSession.isSupported() }
    var isPaired: Bool { wcSession?.isPaired ?? false }
    var isWatchAppInstalled: Bool { wcSession?.isWatchAppInstalled ?? false }
    var isReachable: Bool { wcSession?.isReachable ?? false }
    var isActivated: Bool { wcSession?.activationState == .activated }
    var isSyncing: Bool { !progressByPath.isEmpty }
    var activeTransferCount: Int { progressByPath.count }

    func activate() {
        guard let wcSession else { return }
        wcSession.delegate = self
        wcSession.activate()
        AppLogger.info("WCSession activate requested (iOS)", category: .connectivity)
    }

    // MARK: - Query

    func isSynced(_ track: Track) -> Bool { syncedPaths.contains(relativePath(for: track.fileURL)) }
    func isSyncing(_ track: Track) -> Bool { progressByPath[relativePath(for: track.fileURL)] != nil }
    func syncedCount(in album: Album) -> Int { album.tracks.reduce(0) { $0 + (isSynced($1) ? 1 : 0) } }
    func isSyncing(album: Album) -> Bool { album.tracks.contains { isSyncing($0) } }

    func fileSize(of url: URL) -> Int64 {
        let key = url.path
        if let cached = sizeCache[key] { return cached }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        sizeCache[key] = size
        return size
    }

    func totalBytes(in album: Album) -> Int64 {
        album.tracks.reduce(0) { $0 + fileSize(of: $1.fileURL) }
    }

    /// Smooth 0…1 completion across an album (finished tracks + in-flight fractions).
    func albumSyncFraction(_ album: Album) -> Double {
        let total = album.tracks.count
        guard total > 0 else { return 0 }
        let done = Double(syncedCount(in: album))
        let active = album.tracks.reduce(0.0) { $0 + (progressByPath[relativePath(for: $1.fileURL)] ?? 0) }
        return min(1, (done + active) / Double(total))
    }

    var activeBytesRemaining: Int64 {
        progressByPath.reduce(0) { acc, entry in
            acc + Int64(Double(transferBytes[entry.key] ?? 0) * (1 - entry.value))
        }
    }

    var activeBytesTotal: Int64 {
        progressByPath.keys.reduce(0) { $0 + (transferBytes[$1] ?? 0) }
    }

    private var transferredBytesThisRun: Int64 {
        cumulativeBytes + progressByPath.reduce(0) { acc, entry in
            acc + Int64(Double(transferBytes[entry.key] ?? 0) * entry.value)
        }
    }

    var sessionTransferredBytes: Int64 { transferredBytesThisRun }
    var sessionTotalBytesPending: Int64 { sessionTotalBytes }
    var sessionFraction: Double {
        sessionTotalBytes > 0 ? min(1, Double(transferredBytesThisRun) / Double(sessionTotalBytes)) : 0
    }

    // MARK: - Send

    func sync(tracks: [Track]) {
        guard let wcSession, wcSession.activationState == .activated else {
            AppLogger.warning("Sync skipped: WCSession not activated", category: .connectivity)
            return
        }
        guard wcSession.isWatchAppInstalled else {
            AppLogger.warning("Sync skipped: watch app not installed", category: .connectivity)
            return
        }
        for track in tracks {
            let path = relativePath(for: track.fileURL)
            requestedPaths.insert(path)
            retryCounts[path] = 0
            stuckPaths.remove(path)
            transfer(track: track, session: wcSession)
        }
        persistRequested()
        startMetricsIfNeeded()
        notify()
    }

    /// Cancels any queued/in-flight transfers for the removed paths before
    /// sending the remove command — otherwise a still-queued file lands on the
    /// watch after the delete and the album resurrects.
    func remove(tracks: [Track]) {
        guard let wcSession, wcSession.activationState == .activated else { return }
        let paths = tracks.map { relativePath(for: $0.fileURL) }
        guard !paths.isEmpty else { return }
        let pathSet = Set(paths)
        wcSession.outstandingFileTransfers
            .filter { transfer in
                TransferMetadata(dictionary: transfer.file.metadata).map { pathSet.contains($0.relativePath) } ?? false
            }
            .forEach { $0.cancel() }
        for path in pathSet {
            requestedPaths.remove(path)
            stuckPaths.remove(path)
            retryCounts[path] = nil
            if progressByPath[path] != nil {
                sessionTotalBytes -= transferBytes[path] ?? 0
            }
            observations.removeValue(forKey: path)
            progressByPath.removeValue(forKey: path)
            transferBytes.removeValue(forKey: path)
            awaitingConfirmation.removeValue(forKey: path)
            failedPaths.remove(path)
            diskFullPaths.remove(path)
            syncedPaths.remove(path)
        }
        if progressByPath.isEmpty { stopMetrics() }
        persistRequested()
        sendCommand([SyncKeys.command: SyncKeys.commandRemove, SyncKeys.removePaths: paths])
        AppLogger.info("Requested remove of \(paths.count) tracks", category: .connectivity)
        notify()
    }

    /// Tracks the user asked to sync that the watch has not yet confirmed it holds.
    var unconfirmedCount: Int { requestedPaths.subtracting(syncedPaths).count }
    var stuckCount: Int { stuckPaths.subtracting(syncedPaths).count }

    private func persistRequested() {
        UserDefaults.standard.set(Array(requestedPaths), forKey: requestedKey)
    }

    /// Re-queues every requested track the watch has not acknowledged. The watch's
    /// ack — not the iPhone's `didFinish` — is the source of truth for what landed.
    func reconcile() {
        guard let wcSession, wcSession.activationState == .activated, wcSession.isWatchAppInstalled else { return }
        guard !watchIsFull else { notify(); return }

        let now = Date()
        for (path, sentAt) in awaitingConfirmation where now.timeIntervalSince(sentAt) > confirmationSafetyValve {
            awaitingConfirmation.removeValue(forKey: path)
        }

        let missing = requestedPaths
            .subtracting(syncedPaths)
            .subtracting(progressByPath.keys)
            .subtracting(Set(awaitingConfirmation.keys))
            .subtracting(diskFullPaths)
            .subtracting(stuckPaths)
        guard !missing.isEmpty else { return }

        let tracksByPath = Dictionary(
            Library.shared.allTracks.map { (relativePath(for: $0.fileURL), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var requeued = 0
        var orphaned = 0
        for path in missing {
            let count = retryCounts[path, default: 0]
            if count >= maxRetries {
                stuckPaths.insert(path)
                continue
            }
            guard let track = tracksByPath[path] else {
                forgetOrphanedRequest(path)
                orphaned += 1
                continue
            }
            retryCounts[path] = count + 1
            transfer(track: track, session: wcSession)
            requeued += 1
        }
        if orphaned > 0 {
            persistRequested()
            AppLogger.info("Reconcile: dropped \(orphaned) requested track\(orphaned == 1 ? "" : "s") no longer in the library", category: .connectivity)
        }
        if requeued > 0 {
            AppLogger.info("Reconcile: re-queued \(requeued) unconfirmed track\(requeued == 1 ? "" : "s")", category: .connectivity)
            startMetricsIfNeeded()
        }
        notify()
    }

    /// Drops a requested path whose source track can never be sent (gone from
    /// the library or missing on disk) so it stops counting as unconfirmed.
    private func forgetOrphanedRequest(_ path: String) {
        requestedPaths.remove(path)
        retryCounts[path] = nil
        stuckPaths.remove(path)
        awaitingConfirmation.removeValue(forKey: path)
        diskFullPaths.remove(path)
        failedPaths.remove(path)
    }

    private func transfer(track: Track, session: WCSession) {
        let path = relativePath(for: track.fileURL)
        guard !syncedPaths.contains(path), progressByPath[path] == nil else { return }
        failedPaths.remove(path)
        diskFullPaths.remove(path)
        awaitingConfirmation.removeValue(forKey: path)
        guard FileManager.default.fileExists(atPath: track.fileURL.path) else {
            AppLogger.error("Sync source missing, dropping request: \(path)", category: .connectivity)
            forgetOrphanedRequest(path)
            persistRequested()
            return
        }
        let size = fileSize(of: track.fileURL)

        if let existing = session.outstandingFileTransfers.first(where: {
            TransferMetadata(dictionary: $0.file.metadata)?.relativePath == path
        }) {
            sessionTotalBytes += size
            observe(existing, path: path, size: size)
            AppLogger.info("Re-observing outstanding transfer (no duplicate): \(path)", category: .connectivity)
            return
        }

        let metadata = TransferMetadata(
            relativePath: path, title: track.title, artist: track.artist,
            album: track.albumTitle, trackNumber: track.trackNumber, duration: track.duration
        )
        let fileTransfer = session.transferFile(track.fileURL, metadata: metadata.dictionary)
        sessionTotalBytes += size
        observe(fileTransfer, path: path, size: size)
        AppLogger.info("Queued transfer: \(path) (\(size) bytes)", category: .connectivity)
    }

    private func observe(_ fileTransfer: WCSessionFileTransfer, path: String, size: Int64) {
        progressByPath[path] = fileTransfer.progress.fractionCompleted
        transferBytes[path] = size
        observations[path] = fileTransfer.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
            self?.updateProgress(path: path, fraction: progress.fractionCompleted, finished: progress.isFinished)
        }
    }

    /// Re-attach to transfers the system is still carrying from a previous launch,
    /// so the UI reflects them and re-tapping never enqueues duplicates.
    private func reconcileOutstanding() {
        guard let wcSession else { return }
        var found = false
        for fileTransfer in wcSession.outstandingFileTransfers {
            guard
                let path = TransferMetadata(dictionary: fileTransfer.file.metadata)?.relativePath,
                progressByPath[path] == nil
            else { continue }
            let size = (try? fileTransfer.file.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            sessionTotalBytes += size
            observe(fileTransfer, path: path, size: size)
            found = true
        }
        if found {
            startMetricsIfNeeded()
            notify()
            AppLogger.info("Reconciled \(progressByPath.count) outstanding transfers on launch", category: .connectivity)
        }
    }

    private func updateProgress(path: String, fraction: Double, finished: Bool) {
        DispatchQueue.main.async {
            if finished {
                self.cumulativeBytes += self.transferBytes[path] ?? 0
                self.progressByPath.removeValue(forKey: path)
                self.observations.removeValue(forKey: path)
                self.transferBytes.removeValue(forKey: path)
                // Handed off to the system — NOT confirmed on the watch. Hold it in a
                // grace window so reconcile doesn't immediately re-send before the
                // watch has had a chance to receive + acknowledge it.
                self.awaitingConfirmation[path] = Date()
            } else {
                self.progressByPath[path] = fraction
            }
            let name = finished ? WatchSyncService.stateDidChange : WatchSyncService.progressDidChange
            NotificationCenter.default.post(name: name, object: nil)
        }
    }

    // MARK: - Metrics

    private func startMetricsIfNeeded() {
        guard metricsTimer == nil else { return }
        lastSampleBytes = transferredBytesThisRun
        lastSampleTime = Date()
        metricsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.sampleMetrics()
        }
    }

    private func sampleMetrics() {
        guard !progressByPath.isEmpty else { stopMetrics(); return }
        let now = Date()
        let bytes = transferredBytesThisRun
        if let last = lastSampleTime {
            let dt = now.timeIntervalSince(last)
            if dt > 0 {
                let instant = Double(bytes - lastSampleBytes) / dt
                speedBytesPerSec = speedBytesPerSec <= 0 ? instant : speedBytesPerSec * 0.6 + max(0, instant) * 0.4
            }
        }
        lastSampleBytes = bytes
        lastSampleTime = now
        etaSeconds = speedBytesPerSec > 1024 ? Double(activeBytesRemaining) / speedBytesPerSec : nil
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: WatchSyncService.progressDidChange, object: nil)
        }
    }

    private func stopMetrics() {
        metricsTimer?.invalidate()
        metricsTimer = nil
        speedBytesPerSec = 0
        etaSeconds = nil
        cumulativeBytes = 0
        sessionTotalBytes = 0
        lastSampleBytes = 0
        lastSampleTime = nil
        notify()
    }

    // MARK: - Helpers

    private func relativePath(for url: URL) -> String {
        let documents = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(documents) else { return canonicalSyncPath(url.lastPathComponent) }
        let relative = String(path.dropFirst(documents.count))
        return canonicalSyncPath(relative.hasPrefix("/") ? String(relative.dropFirst()) : relative)
    }

    private func ingest(context: [String: Any]) {
        guard let paths = context[SyncKeys.syncedPaths] as? [String] else { return }
        let confirmed = Set(paths.map(canonicalSyncPath))
        let free = (context[SyncKeys.freeBytes] as? Int64) ?? Int64(context[SyncKeys.freeBytes] as? Int ?? 0)
        let full = context[SyncKeys.isFull] as? Bool ?? false
        let errorPath = (context[SyncKeys.lastErrorPath] as? String).map(canonicalSyncPath)
        let errorReason = (context[SyncKeys.lastErrorReason] as? String).flatMap(StoreFailureReason.init(rawValue:))

        let heartbeatAt = Date()
        DispatchQueue.main.async {
            self.syncedPaths = confirmed
            self.watchFreeBytes = free
            self.watchIsFull = full
            for path in confirmed {
                self.retryCounts[path] = nil
                self.stuckPaths.remove(path)
                self.failedPaths.remove(path)
                self.diskFullPaths.remove(path)
                self.awaitingConfirmation.removeValue(forKey: path)
            }
            for (path, sentAt) in self.awaitingConfirmation
            where heartbeatAt.timeIntervalSince(sentAt) > self.confirmationHeartbeatSlack {
                self.awaitingConfirmation.removeValue(forKey: path)
            }
            if let errorPath, errorReason == .diskFull, !confirmed.contains(errorPath) {
                self.diskFullPaths.insert(errorPath)
                self.observations.removeValue(forKey: errorPath)
                self.progressByPath.removeValue(forKey: errorPath)
                self.awaitingConfirmation.removeValue(forKey: errorPath)
            } else if !full, errorPath == nil {
                self.diskFullPaths.removeAll()
            }
            AppLogger.info("Watch heartbeat: \(confirmed.count) tracks, \(free / 1_048_576) MB free, full=\(full)", category: .connectivity)
            NotificationCenter.default.post(name: WatchSyncService.stateDidChange, object: nil)
            if self.progressByPath.isEmpty { self.reconcile() }
        }
    }

    private func notify() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: WatchSyncService.stateDidChange, object: nil)
        }
    }
}

extension WatchSyncService: WCSessionDelegate {

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        if let error {
            AppLogger.error("WCSession activation error: \(error.localizedDescription)", category: .connectivity)
        }
        AppLogger.info(
            "WCSession activated (iOS): state=\(activationState.rawValue) paired=\(session.isPaired) installed=\(session.isWatchAppInstalled)",
            category: .connectivity
        )
        if session.isWatchAppInstalled {
            ingest(context: session.receivedApplicationContext)
            requestWatchState()
            DispatchQueue.main.async { [weak self] in
                self?.reconcileOutstanding()
                self?.reconcile()
            }
        } else {
            DispatchQueue.main.async { [weak self] in self?.resetForNoWatchApp() }
        }
        notify()
    }

    /// Pulls the watch's current state directly when reachable — deterministic
    /// truth rather than the possibly-stale cached application context.
    func requestWatchState() {
        guard let wcSession, wcSession.activationState == .activated, wcSession.isReachable else { return }
        wcSession.sendMessage([SyncKeys.command: SyncKeys.commandGetState], replyHandler: { [weak self] reply in
            self?.ingest(context: reply)
        }, errorHandler: { error in
            AppLogger.warning("getState failed: \(error.localizedDescription)", category: .connectivity)
        })
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        AppLogger.info("Watch reachability: \(session.isReachable)", category: .connectivity)
        if session.isReachable { requestWatchState() }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        ingest(context: applicationContext)
    }

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        let path = TransferMetadata(dictionary: fileTransfer.file.metadata)?.relativePath
            ?? canonicalSyncPath(fileTransfer.file.fileURL.lastPathComponent)
        if let error {
            let nsError = error as NSError
            if nsError.domain == WCError.errorDomain, nsError.code == WCError.Code.insufficientSpace.rawValue {
                AppLogger.error("Transfer rejected — Apple Watch is full: \(path)", category: .connectivity)
                DispatchQueue.main.async {
                    self.watchIsFull = true
                    self.diskFullPaths.insert(path)
                    if self.progressByPath[path] != nil {
                        self.sessionTotalBytes -= self.transferBytes[path] ?? 0
                    }
                    self.observations.removeValue(forKey: path)
                    self.progressByPath.removeValue(forKey: path)
                    self.transferBytes.removeValue(forKey: path)
                    self.awaitingConfirmation.removeValue(forKey: path)
                    NotificationCenter.default.post(name: WatchSyncService.stateDidChange, object: nil)
                }
            } else {
                AppLogger.error("Transfer failed \(path): \(error.localizedDescription)", category: .connectivity)
                handleFailure(path: path)
            }
        } else {
            AppLogger.info("Transfer handed off \(path) — awaiting watch confirmation", category: .connectivity)
            updateProgress(path: path, fraction: 1, finished: true)
        }
    }

    private func handleFailure(path: String) {
        DispatchQueue.main.async {
            if self.progressByPath[path] != nil {
                self.sessionTotalBytes -= self.transferBytes[path] ?? 0
            }
            self.observations.removeValue(forKey: path)
            self.transferBytes.removeValue(forKey: path)
            self.progressByPath.removeValue(forKey: path)
            self.awaitingConfirmation.removeValue(forKey: path)
            self.failedPaths.insert(path)
            NotificationCenter.default.post(name: WatchSyncService.stateDidChange, object: nil)
        }
    }

    /// Wipes everything off the watch and clears local sync bookkeeping.
    /// Cancels the outstanding transfer backlog first — otherwise queued files
    /// keep arriving on the watch faster than the remove can clear them.
    func removeAll() {
        let outstanding = wcSession?.outstandingFileTransfers ?? []
        outstanding.forEach { $0.cancel() }

        observations.removeAll()
        progressByPath.removeAll()
        transferBytes.removeAll()
        awaitingConfirmation.removeAll()
        requestedPaths.removeAll()
        diskFullPaths.removeAll()
        stuckPaths.removeAll()
        failedPaths.removeAll()
        retryCounts.removeAll()
        watchIsFull = false
        syncedPaths.removeAll()
        metricsTimer?.invalidate()
        metricsTimer = nil
        speedBytesPerSec = 0
        etaSeconds = nil
        sessionTotalBytes = 0
        cumulativeBytes = 0

        persistRequested()
        sendCommand([SyncKeys.command: SyncKeys.commandRemoveAll])
        AppLogger.info("Requested remove-all (cancelled \(outstanding.count) outstanding transfers)", category: .connectivity)
        notify()
    }

    /// Delivers a command immediately when the watch app is reachable (and reflects
    /// the watch's resulting state back), falling back to a guaranteed queued
    /// delivery for when the watch app is asleep.
    private func sendCommand(_ payload: [String: Any]) {
        guard let wcSession else { return }
        if wcSession.isReachable {
            wcSession.sendMessage(payload, replyHandler: { [weak self] reply in
                self?.ingest(context: reply)
            }, errorHandler: { error in
                AppLogger.warning("Command sendMessage failed; queued instead: \(error.localizedDescription)", category: .connectivity)
                wcSession.transferUserInfo(payload)
            })
        } else {
            wcSession.transferUserInfo(payload)
        }
    }

    /// Whether an album's not-yet-synced tracks fit in the watch's reported free space.
    enum FitResult { case fits, tooLarge(needed: Int64, free: Int64), unknown }

    func fitResult(for album: Album) -> FitResult {
        guard watchFreeBytes > 0 else { return .unknown }
        let needed = album.tracks.reduce(Int64(0)) { sum, track in
            isSynced(track) ? sum : sum + fileSize(of: track.fileURL)
        }
        let margin: Int64 = 50 * 1_024 * 1_024
        if needed + margin <= watchFreeBytes { return .fits }
        return .tooLarge(needed: needed, free: watchFreeBytes)
    }

    var diskFullCount: Int { diskFullPaths.count }

    func sessionWatchStateDidChange(_ session: WCSession) {
        AppLogger.info(
            "Watch state changed: paired=\(session.isPaired) installed=\(session.isWatchAppInstalled)",
            category: .connectivity
        )
        DispatchQueue.main.async {
            if !session.isWatchAppInstalled { self.resetForNoWatchApp() }
            NotificationCenter.default.post(name: WatchSyncService.stateDidChange, object: nil)
        }
    }

    /// No watch app means nothing is on the watch — reset the whole sync state so
    /// the UI reflects reality instead of the last cached heartbeat.
    private func resetForNoWatchApp() {
        wcSession?.outstandingFileTransfers.forEach { $0.cancel() }
        observations.removeAll()
        progressByPath.removeAll()
        transferBytes.removeAll()
        awaitingConfirmation.removeAll()
        syncedPaths.removeAll()
        requestedPaths.removeAll()
        diskFullPaths.removeAll()
        stuckPaths.removeAll()
        failedPaths.removeAll()
        retryCounts.removeAll()
        watchIsFull = false
        watchFreeBytes = 0
        metricsTimer?.invalidate()
        metricsTimer = nil
        speedBytesPerSec = 0
        etaSeconds = nil
        sessionTotalBytes = 0
        cumulativeBytes = 0
        persistRequested()
    }

    func sessionDidBecomeInactive(_ session: WCSession) {
        AppLogger.info("WCSession inactive", category: .connectivity)
    }

    func sessionDidDeactivate(_ session: WCSession) {
        AppLogger.info("WCSession deactivated; reactivating", category: .connectivity)
        session.activate()
    }
}
