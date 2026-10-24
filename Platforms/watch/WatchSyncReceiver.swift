import FlaccyCore
import MidgarCore
import Foundation
import Observation
import WatchConnectivity

/// What the watch's storage looks like right now; `usedBytes` is the audio the
/// app holds, the other two describe the volume it lives on.
struct WatchStorage: Sendable, Equatable {
    var usedBytes: Int64
    var freeBytes: Int64
    var totalBytes: Int64

    static let unknown = WatchStorage(usedBytes: 0, freeBytes: 0, totalBytes: 0)
}

/// Observable receiver state the watch UI derives its download/error views from.
/// `isReceiving` is on while the phone reports a run in progress and for a quiet
/// period after each file, so a batch sync reads as one continuous phase.
@MainActor
@Observable
final class WatchSyncStatus {

    var lastErrorReason: StoreFailureReason?

    /// The phone's enrichment job, mirrored. The watch never looks metadata up
    /// itself, so this is the only enrichment state that exists on the wrist —
    /// it is reported, never produced here.
    private(set) var jobProgress: EnrichmentJobProgress = .idle

    /// The run the phone says it is sending: `completed` of `total` tracks.
    private(set) var incoming: SyncBatch = .idle

    private(set) var storage: WatchStorage = .unknown

    private var fileArrivedRecently = false

    @ObservationIgnored private var quietTask: Task<Void, Never>?

    var isReceiving: Bool { incoming.isActive || fileArrivedRecently }

    func apply(jobProgress: EnrichmentJobProgress) {
        self.jobProgress = jobProgress
    }

    func apply(batch: SyncBatch) {
        incoming = batch
    }

    func apply(storage: WatchStorage) {
        guard self.storage != storage else { return }
        self.storage = storage
    }

    func markReceiving() {
        fileArrivedRecently = true
        quietTask?.cancel()
        quietTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            self?.fileArrivedRecently = false
        }
    }

    func markIdle() {
        quietTask?.cancel()
        quietTask = nil
        fileArrivedRecently = false
    }
}

/// Watch side of the sync bridge and the **single source of truth** for what is
/// on the watch. It receives track files from the paired iPhone, stores them
/// idempotently in Documents, and reports its real state (stored paths, space,
/// last error) back to the phone so the phone mirrors it exactly.
///
/// Critical: WatchConnectivity drops the incoming file in a temporary inbox and
/// deletes it the instant `didReceive` returns, so the move must be synchronous.
/// On a full disk the move throws `NSFileWriteOutOfSpaceError` — we detect that,
/// stop, and report it, instead of silently dropping the file.
///
/// Every mutable field below is touched only on `workQueue`; the delegate's
/// callbacks and the UI's calls all funnel through it, so the on-disk library,
/// the in-memory inventory and the reported state cannot disagree.
nonisolated final class WatchSyncReceiver: NSObject, @unchecked Sendable {

    static let shared = WatchSyncReceiver()

    @MainActor let status = WatchSyncStatus()

    /// Invoked on the main queue whenever the on-disk library changes.
    var onLibraryChanged: (() -> Void)?

    /// Leave a margin because the watchOS free-space figure over-reports.
    private static let safetyMargin: Int64 = 40 * 1_024 * 1_024
    private static let heartbeatQuietPeriod: TimeInterval = 1.2
    private static let heartbeatLongestWait: TimeInterval = 6

    private let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    private let workQueue = DispatchQueue(label: "com.midgarcorp.flaccy.watch.sync", qos: .userInitiated)
    private var wcSession: WCSession? { WCSession.isSupported() ? WCSession.default : nil }

    private var inventory: SyncInventory?
    private var lastErrorPath: String?
    private var lastErrorReason: StoreFailureReason?
    private var lastErrorBytesNeeded: Int64 = 0
    private var pendingHeartbeat: DispatchWorkItem?
    private var heartbeatRequestedAt: Date?

    func activate() {
        guard let wcSession else { return }
        wcSession.delegate = self
        wcSession.activate()
        MidgarLog.info("WCSession activate requested (watch)", category: .connectivity)
    }

    /// Deletes what the person removed on the wrist, along with any other file
    /// of the same tracks, and tells the phone so it withdraws them instead of
    /// sending them again.
    func removeFromWatch(paths: [String]) {
        workQueue.async {
            let removed = self.deleteFiles(matching: paths)
            guard !removed.isEmpty else { return }
            self.clearDiskFullIfSpaceReturned()
            self.clearErrorIfRemoved(removed)
            self.scheduleHeartbeat()
            self.notifyLibraryChanged()
            self.tellPhoneRemoved(removed)
            MidgarLog.info("Removed \(removed.count) files on the watch at the person's request", category: .connectivity)
        }
    }

    /// The one place the Documents folder is walked; everything afterwards
    /// updates this value as the disk changes.
    private func currentInventory() -> SyncInventory {
        if let inventory { return inventory }
        let scanned = SyncInventory.scanning(directory: documentsDirectory)
        inventory = scanned
        MidgarLog.info("Watch inventory scanned: \(scanned.count) files, \(scanned.usedBytes / 1_048_576) MB", category: .connectivity)
        return scanned
    }

    private func mutateInventory<T>(_ change: (inout SyncInventory) -> T) -> T {
        var value = currentInventory()
        let result = change(&value)
        inventory = value
        return result
    }

    /// Deletes every file whose track matches one of `paths` by stem and drops
    /// it from the inventory. Returns the stored paths that went away.
    private func deleteFiles(matching paths: [String]) -> [String] {
        var removed: [String] = []
        for path in paths where SyncPathGuard.isSafe(path) {
            let stem = SyncStem.of(path)
            var gone = mutateInventory { $0.remove(stem: stem) }
            if gone.isEmpty, FileManager.default.fileExists(atPath: fileURL(for: path).path) {
                gone = [canonicalSyncPath(path)]
            }
            for stored in gone {
                try? FileManager.default.removeItem(at: fileURL(for: stored))
            }
            removed.append(contentsOf: gone)
        }
        return removed
    }

    private func deleteEverything() -> Int {
        let all = currentInventory().paths
        for path in all {
            try? FileManager.default.removeItem(at: fileURL(for: path))
        }
        mutateInventory { $0.removeAll() }
        return all.count
    }

    private func fileURL(for relativePath: String) -> URL {
        documentsDirectory.appendingPathComponent(relativePath)
    }

    private func setLastError(path: String?, reason: StoreFailureReason?, bytesNeeded: Int64 = 0) {
        lastErrorPath = path
        lastErrorReason = reason
        lastErrorBytesNeeded = bytesNeeded
        DispatchQueue.main.async { self.status.lastErrorReason = reason }
    }

    /// Whether the disk-full condition still holds against live free space, so
    /// the full state self-heals the moment enough room appears (however it was
    /// freed) instead of latching until the exact failed path is removed.
    private func refreshDiskFullState() -> Bool {
        guard lastErrorReason == .diskFull else { return false }
        if freeBytes() - lastErrorBytesNeeded >= Self.safetyMargin {
            setLastError(path: nil, reason: nil)
            return false
        }
        return true
    }

    private func clearDiskFullIfSpaceReturned() {
        _ = refreshDiskFullState()
    }

    private func clearErrorIfRemoved(_ removed: [String]) {
        guard let lastErrorPath, removed.contains(where: { SyncStem.of($0) == SyncStem.of(lastErrorPath) }) else { return }
        setLastError(path: nil, reason: nil)
    }

    /// Volume figures read as 64-bit numbers. The URL resource values for
    /// capacity are plain `Int`, which is 32 bits on the arm64_32 watches
    /// (Series 4 to 8 and the first two SEs) and wraps to a negative number
    /// past 2 GB, so every file would look like it does not fit.
    private func fileSystemBytes(_ key: FileAttributeKey) -> Int64 {
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: documentsDirectory.path)
        return (attributes?[key] as? NSNumber)?.int64Value ?? 0
    }

    private func freeBytes() -> Int64 {
        fileSystemBytes(.systemFreeSize)
    }

    private func totalBytes() -> Int64 {
        fileSystemBytes(.systemSize)
    }

    private func currentStorage() -> WatchStorage {
        WatchStorage(usedBytes: currentInventory().usedBytes, freeBytes: freeBytes(), totalBytes: totalBytes())
    }

    /// The watch's authoritative current state, built from the in-memory
    /// inventory so it costs no disk walk.
    func heartbeatDict() -> [String: Any] {
        let storage = currentStorage()
        var context: [String: Any] = [
            SyncKeys.syncedPaths: currentInventory().paths,
            SyncKeys.freeBytes: storage.freeBytes,
            SyncKeys.isFull: refreshDiskFullState(),
            SyncKeys.usedBytes: storage.usedBytes,
            SyncKeys.totalBytes: storage.totalBytes,
        ]
        if let lastErrorPath, let lastErrorReason {
            context[SyncKeys.lastErrorPath] = lastErrorPath
            context[SyncKeys.lastErrorReason] = lastErrorReason.rawValue
        }
        DispatchQueue.main.async { self.status.apply(storage: storage) }
        return context
    }

    private func sendHeartbeatNow() {
        pendingHeartbeat?.cancel()
        pendingHeartbeat = nil
        heartbeatRequestedAt = nil
        guard let wcSession, wcSession.activationState == .activated else { return }
        let dict = heartbeatDict()
        do {
            try wcSession.updateApplicationContext(dict)
            let count = (dict[SyncKeys.syncedPaths] as? [String])?.count ?? 0
            let free = (dict[SyncKeys.freeBytes] as? Int64) ?? 0
            MidgarLog.info("Watch heartbeat: \(count) tracks, \(free / 1_048_576) MB free", category: .connectivity)
        } catch {
            MidgarLog.error("Heartbeat failed: \(error.localizedDescription)", category: .connectivity)
        }
    }

    /// Sends one heartbeat once the files stop arriving for a moment, but never
    /// later than `heartbeatLongestWait` after the first one asked, so a long
    /// unbroken run still reports progress.
    private func scheduleHeartbeat() {
        let now = Date()
        let firstAsked = heartbeatRequestedAt ?? now
        heartbeatRequestedAt = firstAsked
        let deadline = min(now.addingTimeInterval(Self.heartbeatQuietPeriod), firstAsked.addingTimeInterval(Self.heartbeatLongestWait))
        pendingHeartbeat?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.sendHeartbeatNow() }
        pendingHeartbeat = item
        workQueue.asyncAfter(deadline: .now() + max(0, deadline.timeIntervalSince(now)), execute: item)
    }

    private func notifyLibraryChanged() {
        DispatchQueue.main.async { self.onLibraryChanged?() }
    }

    private func tellPhoneRemoved(_ paths: [String]) {
        guard let wcSession, wcSession.activationState == .activated else {
            MidgarLog.notice("Removal not reported to the phone: session not active", category: .connectivity)
            return
        }
        wcSession.transferUserInfo([
            SyncKeys.command: SyncKeys.commandRemoved,
            SyncKeys.removePaths: Array(Set(paths)).sorted(),
        ])
    }

    /// Reads the phone's half of the application context. An absent key means
    /// the phone has nothing to say about it right now, which is not the same as
    /// an idle job or an empty run — the last state stands until the phone
    /// replaces it.
    private func ingestPhoneContext(_ context: [String: Any]) {
        let progress = EnrichmentJobTransfer.decode(context[SyncKeys.enrichmentJob])
        let batch = SyncBatchTransfer.decode(context[SyncKeys.syncBatch])
        guard progress != nil || batch != nil else { return }
        if let batch {
            MidgarLog.info("Phone batch: \(batch.completed)/\(batch.total), preparing=\(batch.preparing)", category: .connectivity)
        }
        DispatchQueue.main.async {
            if let progress { self.status.apply(jobProgress: progress) }
            if let batch { self.status.apply(batch: batch) }
        }
    }

    private func isOutOfSpace(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileWriteOutOfSpaceError { return true }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            return underlying.domain == NSPOSIXErrorDomain && underlying.code == Int(ENOSPC)
        }
        return false
    }

    private func reportStoreFailure(path: String, reason: StoreFailureReason, bytesNeeded: Int64 = 0) {
        setLastError(path: path, reason: reason, bytesNeeded: bytesNeeded)
        sendHeartbeatNow()
    }

    private func size(ofFileAt url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    /// Puts `source` at `destination`, replacing a file already there without
    /// ever leaving the destination missing: the system swaps the two and only
    /// then discards the old one.
    private func placeAtomically(_ source: URL, at destination: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: source)
        } else {
            try fileManager.moveItem(at: source, to: destination)
        }
    }

    func store(_ file: WCSessionFile) {
        store(fileURL: file.fileURL, metadataDictionary: file.metadata)
    }

    /// The delivery logic behind `store(_:)`, taking the file and its metadata
    /// directly so it can be driven without a live WatchConnectivity transfer.
    func store(fileURL: URL, metadataDictionary: [String: Any]?) {
        guard let metadata = TransferMetadata(dictionary: metadataDictionary) else {
            MidgarLog.error("Received file with no relativePath metadata", category: .connectivity)
            return
        }
        let path = metadata.relativePath
        guard SyncPathGuard.isSafe(path) else {
            MidgarLog.error("Refused unsafe path '\(path)'", category: .connectivity)
            reportStoreFailure(path: path, reason: .writeFailed)
            return
        }

        let incomingSize = size(ofFileAt: fileURL)
        DispatchQueue.main.async { self.status.markReceiving() }

        if metadata.bytes > 0, incomingSize != metadata.bytes {
            MidgarLog.error("Size mismatch for \(path): got \(incomingSize), expected \(metadata.bytes)", category: .connectivity)
            reportStoreFailure(path: path, reason: .writeFailed)
            return
        }

        if freeBytes() - incomingSize < Self.safetyMargin {
            MidgarLog.notice("Watch full — skipping \(path) (\(freeBytes() / 1_048_576) MB free)", category: .connectivity)
            reportStoreFailure(path: path, reason: .diskFull, bytesNeeded: incomingSize)
            return
        }

        do {
            try placeAtomically(fileURL, at: self.fileURL(for: path))
        } catch {
            let outOfSpace = isOutOfSpace(error)
            MidgarLog.error("Failed to store \(path): \(error.localizedDescription)", category: .connectivity)
            reportStoreFailure(path: path, reason: outOfSpace ? .diskFull : .writeFailed, bytesNeeded: outOfSpace ? incomingSize : 0)
            return
        }

        let displaced = mutateInventory { $0.insert(path: path, size: incomingSize) }
        removeDisplaced(displaced, replacedBy: path)
        setLastError(path: nil, reason: nil)
        MidgarLog.info("Stored \(path) (\(incomingSize / 1_024) KB)", category: .connectivity)
        scheduleHeartbeat()
        notifyLibraryChanged()
    }

    /// A track is held once: when a re-encode lands, the file it replaces under
    /// another extension is deleted.
    private func removeDisplaced(_ displaced: [String], replacedBy path: String) {
        for sibling in displaced {
            try? FileManager.default.removeItem(at: fileURL(for: sibling))
            MidgarLog.info("Removed \(sibling), replaced by \(path)", category: .connectivity)
        }
    }

    private func handleCommand(_ userInfo: [String: Any]) {
        switch userInfo[SyncKeys.command] as? String {
        case SyncKeys.commandRemoveAll:
            let count = deleteEverything()
            setLastError(path: nil, reason: nil)
            MidgarLog.info("Removed all \(count) tracks", category: .connectivity)
            sendHeartbeatNow()
            notifyLibraryChanged()
        case SyncKeys.commandRemove:
            guard let paths = userInfo[SyncKeys.removePaths] as? [String] else { return }
            let removed = deleteFiles(matching: paths)
            clearDiskFullIfSpaceReturned()
            clearErrorIfRemoved(removed)
            MidgarLog.info("Phone removed \(removed.count) files (\(paths.count) requested)", category: .connectivity)
            sendHeartbeatNow()
            notifyLibraryChanged()
        case SyncKeys.commandGetState:
            sendHeartbeatNow()
        default:
            #if DEBUG && targetEnvironment(simulator)
            simulateDelivery(userInfo)
            #endif
        }
    }
}

extension WatchSyncReceiver: WCSessionDelegate {

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        if let error {
            MidgarLog.error("WCSession activation error (watch): \(error.localizedDescription)", category: .connectivity)
        }
        MidgarLog.info("WCSession activated (watch): state=\(activationState.rawValue)", category: .connectivity)
        let context = SyncPayload(session.receivedApplicationContext)
        workQueue.async {
            self.ingestPhoneContext(context.values)
            self.sendHeartbeatNow()
        }
        WatchPlayLog.shared.sessionDidActivate()
        deliveryDidFinish()
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        workQueue.sync { ingestPhoneContext(applicationContext) }
        deliveryDidFinish()
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        workQueue.sync { store(file) }
        deliveryDidFinish()
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        workQueue.sync { handleCommand(userInfo) }
        deliveryDidFinish()
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        workQueue.sync { handleCommand(message) }
        deliveryDidFinish()
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        let reply = workQueue.sync { () -> [String: Any] in
            handleCommand(message)
            return heartbeatDict()
        }
        replyHandler(reply)
        deliveryDidFinish()
    }

    func session(_ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: Error?) {
        if let error {
            MidgarLog.notice("User-info transfer failed: \(error.localizedDescription)", category: .connectivity)
        }
        WatchPlayLog.shared.transferDidFinish(userInfoTransfer, error: error)
    }

    private func deliveryDidFinish() {
        Task { @MainActor in WatchBackgroundTasks.connectivityDidDeliver() }
    }
}

#if DEBUG && targetEnvironment(simulator)
nonisolated extension WatchSyncReceiver {

    func exerciseStore(fileURL: URL, metadata: [String: Any]) {
        workQueue.sync { store(fileURL: fileURL, metadataDictionary: metadata) }
    }

    func exerciseHeartbeat() -> [String: Any] {
        workQueue.sync { heartbeatDict() }
    }

    func exerciseCommand(_ payload: [String: Any]) {
        workQueue.sync { handleCommand(payload) }
    }
}
#endif

#if DEBUG && targetEnvironment(simulator)
nonisolated extension WatchSyncReceiver {

    /// Materialises a file the phone says it just handed over, standing in for
    /// the file transfer the simulator pair never delivers.
    fileprivate func simulateDelivery(_ payload: [String: Any]) {
        guard payload[SyncKeys.command] as? String == "debugDeliver",
              let path = (payload[SyncKeys.removePaths] as? [String])?.first else { return }
        let bytes = (payload[SyncKeys.bytes] as? NSNumber)?.int64Value ?? 0
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: staging.path, contents: Data(count: Int(bytes)))
        let metadata = TransferMetadata(relativePath: path, title: "", artist: "", album: "", trackNumber: 0, duration: 0, bytes: bytes)
        store(fileURL: staging, metadataDictionary: metadata.dictionary)
    }
}
#endif