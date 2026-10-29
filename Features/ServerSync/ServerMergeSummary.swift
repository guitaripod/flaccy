import FlaccyEngine
import Foundation
import MidgarCore

/// What the engine says the first sync combined, worded for the one informational sheet after connecting.
nonisolated struct ServerMergeSummary: Equatable, Sendable {

    let playlistNames: [String]
    let lovesAdded: Int

    init?(_ report: ServerMergeReport) {
        guard !report.isEmpty else { return nil }
        playlistNames = report.playlistNames
        lovesAdded = report.lovesAdded
    }
}

/// Waits for the first sync after connecting to settle and for the server's songs to reach the library, then asks the engine what
/// it combined. The summary waits here until a screen takes it, so it is shown once.
@MainActor
final class ServerMergeReporter {

    static let shared = ServerMergeReporter()
    static let didFinish = Notification.Name("ServerMergeReporterDidFinish")

    nonisolated private static let settleTimeout: Duration = .seconds(180)

    private(set) var pending: ServerMergeSummary?
    private var task: Task<Void, Never>?

    func begin(serverID: String) {
        task?.cancel()
        task = Task { [weak self] in
            guard await Self.firstSyncSettled() else { return }
            _ = try? await RemoteCatalogSync.shared.sync(serverID: serverID)
            await ServerSyncService.engine.resolveGhosts()
            let report = await ServerSyncService.engine.firstConnectMerge()
            guard !Task.isCancelled, let summary = ServerMergeSummary(report) else { return }
            self?.pending = summary
            NotificationCenter.default.post(name: Self.didFinish, object: nil)
        }
    }

    func take() -> ServerMergeSummary? {
        defer { pending = nil }
        return pending
    }

    func cancel() {
        task?.cancel()
        pending = nil
    }

    private static func firstSyncSettled() async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await status in await ServerSyncService.engine.statusUpdates() {
                    switch status {
                    case .upToDate: return true
                    case .syncing: continue
                    default: return false
                    }
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: settleTimeout)
                return false
            }
            let settled = await group.next() ?? false
            group.cancelAll()
            return settled
        }
    }
}
