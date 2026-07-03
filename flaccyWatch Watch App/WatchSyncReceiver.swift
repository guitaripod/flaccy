import FlaccyCore
import Foundation
import Observation
import WatchConnectivity

/// Observable receiver state the watch UI derives its download/error views from.
/// `isReceiving` flips on with every incoming file and decays after a quiet
/// period, so a batch sync reads as one continuous "receiving" phase.
@MainActor
@Observable
final class WatchSyncStatus {

    private(set) var isReceiving = false
    var lastErrorReason: StoreFailureReason?

    @ObservationIgnored private var quietTask: Task<Void, Never>?

    func markReceiving() {
        isReceiving = true
        quietTask?.cancel()
        quietTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            self?.isReceiving = false
        }
    }

    func markIdle() {
        quietTask?.cancel()
        quietTask = nil
        isReceiving = false
    }
}

/// Watch side of the sync bridge and the **single source of truth** for what is
/// on the watch. It receives track files from the paired iPhone, stores them
/// idempotently in Documents, and reports its real state (stored paths, free
/// space, last error) back to the phone so the phone mirrors it exactly.
///
/// Critical: WatchConnectivity drops the incoming file in a temporary inbox and
/// deletes it the instant `didReceive` returns, so the move must be synchronous.
/// On a full disk the move throws `NSFileWriteOutOfSpaceError` — we detect that,
/// stop, and report it, instead of silently dropping the file.
final class WatchSyncReceiver: NSObject {

    static let shared = WatchSyncReceiver()

    @MainActor let status = WatchSyncStatus()

    /// Invoked on the main queue whenever the on-disk library changes.
    var onLibraryChanged: (() -> Void)?

    /// Leave a margin because the watchOS free-space figure over-reports.
    private static let safetyMargin: Int64 = 40 * 1_024 * 1_024

    private let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    private var wcSession: WCSession? { WCSession.isSupported() ? WCSession.default : nil }

    private var lastErrorPath: String?
    private var lastErrorReason: StoreFailureReason?
    private var lastErrorBytesNeeded: Int64 = 0

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

    func activate() {
        guard let wcSession else { return }
        wcSession.delegate = self
        wcSession.activate()
        AppLogger.info("WCSession activate requested (watch)", category: .connectivity)
    }

    // MARK: - Heartbeat (the watch's authoritative state)

    private func freeBytes() -> Int64 {
        let values = try? documentsDirectory.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return Int64(values?.volumeAvailableCapacity ?? 0)
    }

    /// The watch's authoritative current state — derived fresh from disk every
    /// time, so it's always deterministic, never cached/guessed.
    private func heartbeatDict() -> [String: Any] {
        var context: [String: Any] = [
            SyncKeys.syncedPaths: LibraryScanner.audioFileRelativePaths(in: documentsDirectory),
            SyncKeys.freeBytes: freeBytes(),
            SyncKeys.isFull: refreshDiskFullState(),
        ]
        if let lastErrorPath, let lastErrorReason {
            context[SyncKeys.lastErrorPath] = lastErrorPath
            context[SyncKeys.lastErrorReason] = lastErrorReason.rawValue
        }
        return context
    }

    private func sendHeartbeat() {
        guard let wcSession, wcSession.activationState == .activated else { return }
        let dict = heartbeatDict()
        do {
            try wcSession.updateApplicationContext(dict)
            let count = (dict[SyncKeys.syncedPaths] as? [String])?.count ?? 0
            let free = (dict[SyncKeys.freeBytes] as? Int64) ?? 0
            AppLogger.info("Watch heartbeat: \(count) tracks, \(free / 1_048_576) MB free", category: .connectivity)
        } catch {
            AppLogger.error("Heartbeat failed: \(error.localizedDescription)", category: .connectivity)
        }
    }

    private func notifyLibraryChanged() {
        DispatchQueue.main.async { self.onLibraryChanged?() }
    }

    private func isOutOfSpace(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileWriteOutOfSpaceError { return true }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            return underlying.domain == NSPOSIXErrorDomain && underlying.code == Int(ENOSPC)
        }
        return false
    }
}

extension WatchSyncReceiver: WCSessionDelegate {

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        if let error {
            AppLogger.error("WCSession activation error (watch): \(error.localizedDescription)", category: .connectivity)
        }
        AppLogger.info("WCSession activated (watch): state=\(activationState.rawValue)", category: .connectivity)
        sendHeartbeat()
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard let metadata = TransferMetadata(dictionary: file.metadata) else {
            AppLogger.error("Received file with no relativePath metadata", category: .connectivity)
            return
        }
        let destination = documentsDirectory.appendingPathComponent(metadata.relativePath)
        let fileManager = FileManager.default
        let incomingSize = (try? file.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0

        DispatchQueue.main.async { self.status.markReceiving() }

        if freeBytes() - incomingSize < Self.safetyMargin {
            setLastError(path: metadata.relativePath, reason: .diskFull, bytesNeeded: incomingSize)
            AppLogger.warning("Watch full — skipping \(metadata.relativePath) (\(freeBytes() / 1_048_576) MB free)", category: .connectivity)
            sendHeartbeat()
            return
        }

        do {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: file.fileURL, to: destination)
            setLastError(path: nil, reason: nil)
            AppLogger.info("Stored \(metadata.relativePath)", category: .connectivity)
        } catch {
            let outOfSpace = isOutOfSpace(error)
            setLastError(
                path: metadata.relativePath,
                reason: outOfSpace ? .diskFull : .writeFailed,
                bytesNeeded: outOfSpace ? incomingSize : 0
            )
            AppLogger.error("Failed to store \(metadata.relativePath): \(error.localizedDescription)", category: .connectivity)
            sendHeartbeat()
            return
        }
        sendHeartbeat()
        notifyLibraryChanged()
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        handleCommand(userInfo)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        handleCommand(message)
        replyHandler(heartbeatDict())
    }

    private func handleCommand(_ userInfo: [String: Any]) {
        let command = userInfo[SyncKeys.command] as? String

        if command == SyncKeys.commandRemoveAll {
            let paths = LibraryScanner.audioFileRelativePaths(in: documentsDirectory)
            for path in paths {
                try? FileManager.default.removeItem(at: documentsDirectory.appendingPathComponent(path))
            }
            setLastError(path: nil, reason: nil)
            AppLogger.info("Removed all \(paths.count) tracks", category: .connectivity)
            sendHeartbeat()
            notifyLibraryChanged()
            return
        }

        guard command == SyncKeys.commandRemove,
              let paths = userInfo[SyncKeys.removePaths] as? [String]
        else { return }

        for path in paths {
            let url = documentsDirectory.appendingPathComponent(canonicalSyncPath(path))
            try? FileManager.default.removeItem(at: url)
        }
        let removalClearsError = lastErrorReason == .diskFull
            || lastErrorPath.map { errorPath in paths.contains { canonicalSyncPath($0) == errorPath } } == true
        if removalClearsError {
            setLastError(path: nil, reason: nil)
        }
        AppLogger.info("Removed \(paths.count) tracks", category: .connectivity)
        sendHeartbeat()
        notifyLibraryChanged()
    }
}
