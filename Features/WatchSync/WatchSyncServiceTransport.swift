import FlaccyCore
import MidgarCore
import Foundation
import WatchConnectivity

extension WatchSyncService {

    /// Starts watching one transfer. The first callback is delivered at once,
    /// so a transfer that finished while nobody was looking completes now
    /// instead of sitting in flight forever.
    func attach(_ transfer: WCSessionFileTransfer, stem: String) {
        transfers[stem] = transfer
        observations[stem] = transfer.progress.observe(\.fractionCompleted, options: [.initial, .new]) { [weak self] progress, _ in
            let fraction = progress.fractionCompleted
            let finished = progress.isFinished
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.transferProgressed(stem: stem, fraction: fraction, finished: finished) }
            }
        }
    }

    private func transferProgressed(stem: String, fraction: Double, finished: Bool) {
        guard transfers[stem] != nil else { return }
        if finished {
            handedOff(stem)
        } else {
            ledger.markSending(stem: stem, fraction: fraction)
            notifyProgress()
        }
    }

    func handedOff(_ stem: String) {
        guard let phase = ledger.phase(of: stem) else { return }
        #if DEBUG && targetEnvironment(simulator)
        deliverToSimulatedWatch(stem)
        #endif
        switch phase {
        case .preparing, .sending:
            ledger.markHandedOff(stem: stem, now: Date())
            MidgarLog.info("Transfer handed off \(stem) — awaiting watch confirmation", category: .connectivity)
        default:
            break
        }
        settle(stem)
        pump()
    }

    private func transferFailed(stem: String, failure: WatchSyncLedger.Failure, description: String) {
        MidgarLog.error("Transfer failed \(stem): \(description)", category: .connectivity)
        guard ledger.requested.contains(stem) else {
            settle(stem)
            return
        }
        settle(stem)
        ledger.markFailed(stem: stem, failure: failure, now: Date())
        pump()
    }

    /// Takes over transfers the system kept carrying from a previous launch and
    /// cancels any nobody wants any more.
    func adoptOutstandingTransfers() {
        guard let wcSession else { return }
        var adopted = 0
        for transfer in wcSession.outstandingFileTransfers where !transfer.progress.isFinished {
            guard let metadata = TransferMetadata(dictionary: transfer.file.metadata) else {
                transfer.cancel()
                continue
            }
            let stem = SyncStem.of(metadata.relativePath)
            guard transfers[stem] == nil else { continue }
            let bytes = metadata.bytes > 0 ? metadata.bytes : fileSize(of: transfer.file.fileURL)
            if ledger.adopt(stem: stem, bytes: bytes, fraction: transfer.progress.fractionCompleted) {
                bytesByStem[stem] = bytes
                runStems.insert(stem)
                attach(transfer, stem: stem)
                adopted += 1
            } else {
                transfer.cancel()
            }
        }
        if adopted > 0 {
            MidgarLog.info("Adopted \(adopted) outstanding transfers on launch", category: .connectivity)
        }
    }

    func ingest(context: [String: Any]) {
        guard let paths = context[SyncKeys.syncedPaths] as? [String] else { return }
        let confirmed = Set(paths.map(SyncStem.of))
        let free = Self.int64(context[SyncKeys.freeBytes])
        let used = Self.int64(context[SyncKeys.usedBytes])
        let total = Self.int64(context[SyncKeys.totalBytes])
        let full = context[SyncKeys.isFull] as? Bool ?? false
        let errorPath = (context[SyncKeys.lastErrorPath] as? String).map(SyncStem.of)
        let errorReason = (context[SyncKeys.lastErrorReason] as? String).flatMap(StoreFailureReason.init(rawValue:))

        hasHeartbeat = true
        lastConfirmed = confirmed
        applyHeartbeat(used: used, total: total)
        ledger.ingest(confirmed: confirmed, watchFreeBytes: free, watchIsFull: full, now: Date())
        if let errorPath, errorReason == .diskFull, !confirmed.contains(errorPath) {
            discardWork(for: errorPath)
            ledger.markFailed(stem: errorPath, failure: .diskFull, now: Date())
        }
        for stem in confirmed {
            transfers[stem]?.cancel()
            settle(stem)
        }
        MidgarLog.info("Watch heartbeat: \(confirmed.count) tracks, \(free / 1_048_576) MB free, full=\(full)", category: .connectivity)
        persistRequested()
        pump()
    }

    private static func int64(_ value: Any?) -> Int64 {
        if let number = value as? Int64 { return number }
        return Int64((value as? NSNumber)?.int64Value ?? 0)
    }

    /// Pulls the watch's state directly when it is reachable: deterministic
    /// truth rather than the possibly stale cached application context.
    func requestWatchState() {
        guard let wcSession, wcSession.activationState == .activated, wcSession.isReachable else { return }
        wcSession.sendMessage([SyncKeys.command: SyncKeys.commandGetState], replyHandler: { @Sendable [weak self] reply in
            let payload = SyncPayload(reply)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.ingest(context: payload.values) } }
        }, errorHandler: { @Sendable error in
            MidgarLog.notice("getState failed: \(error.localizedDescription)", category: .connectivity)
        })
    }

    /// Delivers a command at once when the watch app is reachable, falling back
    /// to a queued delivery for when it is asleep.
    func sendCommand(_ payload: [String: Any]) {
        guard let wcSession else { return }
        if wcSession.isReachable {
            let command = SyncPayload(payload)
            wcSession.sendMessage(payload, replyHandler: { @Sendable [weak self] reply in
                let answer = SyncPayload(reply)
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.ingest(context: answer.values) } }
            }, errorHandler: { @Sendable error in
                MidgarLog.notice("Command sendMessage failed; queued instead: \(error.localizedDescription)", category: .connectivity)
                WCSession.default.transferUserInfo(command.values)
            })
        } else {
            wcSession.transferUserInfo(payload)
        }
    }

    func publishBatch() {
        let remaining = runStems.filter { !ledger.isOnWatch($0) }.count
        let batch = SyncBatch(total: runStems.count, remaining: remaining, preparing: !preparingStems.isEmpty)
        guard batch != latestBatch else { return }
        latestBatch = batch
        scheduleContextPublish()
    }

    func scheduleContextPublish() {
        contextTimer?.invalidate()
        contextTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushContext() }
        }
    }

    /// Mirrors the phone's side of the story onto the wrist in one application
    /// context: the enrichment job and the run being sent. The context replaces
    /// the previous one wholesale, so it always carries both, and a payload that
    /// says nothing new is never sent because every update costs the radio.
    private func flushContext() {
        guard let wcSession, wcSession.activationState == .activated, wcSession.isWatchAppInstalled else { return }
        var context: [String: Data] = [:]
        if let latestJob, let payload = EnrichmentJobTransfer.encode(latestJob) {
            context[SyncKeys.enrichmentJob] = payload
        }
        if let payload = SyncBatchTransfer.encode(latestBatch) {
            context[SyncKeys.syncBatch] = payload
        }
        guard context != lastSentContext else { return }
        do {
            try wcSession.updateApplicationContext(context)
            lastSentContext = context
        } catch {
            MidgarLog.notice("Phone context update failed: \(error.localizedDescription)", category: .connectivity)
        }
    }

    private func handleWatchCommand(_ payload: [String: Any]) {
        switch payload[SyncKeys.command] as? String {
        case SyncKeys.commandRemoved:
            let paths = payload[SyncKeys.removePaths] as? [String] ?? []
            let stems = paths.map(SyncStem.of)
            for stem in stems { discardWork(for: stem) }
            ledger.withdraw(stems)
            runStems.subtract(stems)
            persistRequested()
            MidgarLog.info("Watch removed \(stems.count) tracks; no longer requested", category: .connectivity)
            afterLedgerChange()
        case SyncKeys.commandPlays:
            let entries = (payload[SyncKeys.plays] as? [[String: Any]] ?? []).compactMap { WatchPlayEntry(dictionary: $0) }
            WatchPlayIngestor.ingest(entries, service: self)
        default:
            break
        }
    }

    private func sessionActivated(state: WCSessionActivationState, error: Error?) {
        if let error {
            MidgarLog.error("WCSession activation error: \(error.localizedDescription)", category: .connectivity)
        }
        guard let session = wcSession else { return }
        MidgarLog.info(
            "WCSession activated (iOS): state=\(state.rawValue) paired=\(session.isPaired) installed=\(session.isWatchAppInstalled)",
            category: .connectivity
        )
        guard session.isWatchAppInstalled else {
            resetForNoWatchApp()
            return
        }
        Task { await transcoder.purgeStale(keeping: outstandingFileURLs(), olderThan: 3_600) }
        refreshRequestedFromLibrary()
        adoptOutstandingTransfers()
        ingest(context: session.receivedApplicationContext)
        flushContext()
        requestWatchState()
        pump()
    }

    private func outstandingFileURLs() -> Set<URL> {
        Set(wcSession?.outstandingFileTransfers.map { $0.file.fileURL } ?? [])
    }
}

extension WatchSyncService: WCSessionDelegate {

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { WatchSyncService.shared.sessionActivated(state: activationState, error: error) }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                MidgarLog.info("Watch reachability: \(reachable)", category: .connectivity)
                if reachable { WatchSyncService.shared.requestWatchState() }
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let context = SyncPayload(applicationContext)
        DispatchQueue.main.async {
            MainActor.assumeIsolated { WatchSyncService.shared.ingest(context: context.values) }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        let payload = SyncPayload(userInfo)
        DispatchQueue.main.async {
            MainActor.assumeIsolated { WatchSyncService.shared.handleWatchCommand(payload.values) }
        }
    }

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        let stem = TransferMetadata(dictionary: fileTransfer.file.metadata)
            .map { SyncStem.of($0.relativePath) }
            ?? SyncStem.of(fileTransfer.file.fileURL.lastPathComponent)
        let nsError = error as NSError?
        let isOutOfSpace = nsError?.domain == WCError.errorDomain
            && nsError?.code == WCError.Code.insufficientSpace.rawValue
        let isCancelled = nsError?.domain == NSCocoaErrorDomain && nsError?.code == NSUserCancelledError
        let description = error?.localizedDescription
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let service = WatchSyncService.shared
                guard let description else {
                    service.handedOff(stem)
                    return
                }
                guard !isCancelled else { return }
                service.transferFailed(stem: stem, failure: isOutOfSpace ? .diskFull : .transient, description: description)
            }
        }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        let installed = session.isWatchAppInstalled
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                MidgarLog.info("Watch state changed: installed=\(installed)", category: .connectivity)
                let service = WatchSyncService.shared
                if installed { service.pump() } else { service.resetForNoWatchApp() }
                service.notify()
            }
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        MidgarLog.info("WCSession inactive", category: .connectivity)
    }

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        MidgarLog.info("WCSession deactivated; reactivating", category: .connectivity)
        session.activate()
    }
}

#if DEBUG && targetEnvironment(simulator)
extension WatchSyncService {

    /// Set once at launch by the simulator-only demo and exercise flags, before any transfer starts.
    nonisolated(unsafe) static var simulatesDelivery = false

    /// The simulator pair accepts file transfers but never delivers them, so a
    /// run that wants to see the watch's heartbeat and removal answers asks the
    /// watch to materialise the file it was just handed.
    func deliverToSimulatedWatch(_ stem: String) {
        guard Self.simulatesDelivery, let output = prepared[stem], let track = track(forStem: stem) else { return }
        let destination = SyncStem.destinationPath(forSource: relativePath(for: track.fileURL), encoded: output.wasEncoded)
        sendCommand([
            SyncKeys.command: "debugDeliver",
            SyncKeys.removePaths: [destination],
            SyncKeys.bytes: output.bytes,
        ])
    }
}
#endif
