import FlaccyCore
import FlaccyEngine
import Foundation
import MidgarCore

/// The real follow-up of a successful enrollment: adds the music, and starts the reporter that will say what the first sync
/// combined. A music server that cannot be added is logged and reported, never fatal: the sync is already running.
@MainActor
struct FlaccyServerSetupFollowUp: ServerSetupFollowUp {

    func finish(_ connection: ServerSetupConnection) async -> Bool {
        ServerSyncLifecycle.shared.connected()
        do {
            let record = try await FlaccyServerLibrary.register(connection)
            ServerMergeReporter.shared.begin(serverID: record.id)
            return true
        } catch {
            MidgarLog.error("Adding the music of \(connection.serverName) failed: \(error.localizedDescription)", category: .sync)
            return false
        }
    }
}
