import FlaccyEngine
import Foundation
import MidgarCore

/// Whether a server's music shows in the library, the "Show arch's music in my library" switch. Hiding keeps the server, its
/// sign-in, its downloads and the playlist places that held its songs; showing syncs the catalog again.
nonisolated enum RemoteLibraryVisibility {

    private static let key = "flaccy.remote.hiddenLibraries"

    static func isShown(serverID: String) -> Bool {
        !hiddenIDs.contains(serverID)
    }

    static func setShown(_ shown: Bool, serverID: String) async throws {
        var hidden = hiddenIDs
        if shown {
            hidden.remove(serverID)
            UserDefaults.standard.set(Array(hidden), forKey: key)
            _ = try await RemoteCatalogSync.shared.sync(serverID: serverID)
        } else {
            hidden.insert(serverID)
            UserDefaults.standard.set(Array(hidden), forKey: key)
            await RemoteCatalogSync.shared.cancel(serverID: serverID)
            let paths = try DatabaseManager.shared.deleteRemoteTracks(serverID: serverID)
            RemoteSongDirectory.shared.invalidate(paths: paths)
            await RemoteCatalogSync.shared.publishRemoval(paths: paths)
            RemoteLog.info("Hid the music of server \(serverID): \(paths.count) songs left the library")
        }
    }

    private static var hiddenIDs: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }
}
