import FlaccyCore
import FlaccyEngine
import FlaccyServerEmbed
import Foundation
import MidgarCore

/// Makes this Mac a device of its own server over loopback, through the same engine every other Flaccy Server uses, so its
/// playlists, loves and plays sync with its own library like any other device's. A Mac that already syncs with a different
/// Flaccy Server keeps doing so: the engine follows one server, and sharing never takes it over.
@MainActor
struct ThisMacEnroller: ThisMacEnrolling {

    func needsEnrolling(with server: URL) -> Bool {
        guard let connected = ServerSyncService.engine.connectedServer else { return true }
        guard connected.url == server else { return FlaccyServerLibrary.isThisDevicesOwn(connected.url) }
        if case .deviceRemoved = FlaccyServerStatusStore.shared.status { return true }
        return false
    }

    func enroll(with server: URL, code: String, serverName: String) async throws {
        let engine = ServerSyncService.engine
        if engine.connectedServer != nil { try await engine.disconnect() }
        let link = FlaccyServerLink(baseURL: server, enrollmentCode: code, name: serverName)
        try await engine.connect(link: link, deviceName: ServerSyncService.deviceName)
        ServerSyncLifecycle.shared.connected()
        MidgarLog.info("This Mac joined its own library server \(serverName) over loopback", category: .sync)
    }
}
