import FlaccyCore
import FlaccyEngine
import Foundation
import MidgarCore

/// The server's own screen on iPhone and Mac: Status, Library, Sync, Devices and Disconnect, as docs/server/UX.md section 4
/// words them. The screens render the properties and call the actions; `onChange` tells them to render again.
@MainActor
final class FlaccyServerDetailViewModel {

    nonisolated struct DeviceRow: Hashable, Identifiable {
        let id: String
        let name: String
        let isCurrent: Bool
        let lastSeen: String?
    }

    enum DevicesState: Equatable {
        case loading
        case loaded([DeviceRow])
        case failed(String)
    }

    var onChange: (() -> Void)?
    var onProRequested: (() -> Void)?

    private(set) var serverID: String
    private(set) var name: String
    private(set) var address: String
    private(set) var devices: DevicesState = .loading
    private var observers: [NSObjectProtocol] = []
    private let engine = ServerSyncService.engine

    init(record: RemoteServerRecord) {
        serverID = record.id
        name = record.name
        address = FlaccyServerDetailViewModel.displayAddress(record.baseURL)
    }

    var statusLine: String {
        FlaccyServerStatusStore.shared.status.statusLine
    }

    var lastSyncedLine: String? {
        guard let date = FlaccyServerStatusStore.shared.lastSyncedAt else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return String(localized: "Last synced \(formatter.string(from: date))")
    }

    var songs: String {
        RemoteCopy.songs((try? DatabaseManager.shared.fetchRemoteSongCounts()[serverID]) ?? 0)
    }

    var isLibraryShown: Bool {
        RemoteLibraryVisibility.isShown(serverID: serverID)
    }

    var isPro: Bool {
        PurchaseManager.shared.includesServerSync
    }

    var isSyncOn: Bool {
        FlaccyServerStatusStore.shared.status != .paused
    }

    var libraryToggleTitle: String {
        String(localized: "Show \(name)\u{2019}s music in my library")
    }

    var syncToggleTitle: String {
        String(localized: "Sync with \(name)")
    }

    var proRowTitle: String {
        String(localized: "Sync playlists, loves and history \u{00B7} Pro")
    }

    var disconnectTitle: String {
        String(localized: "Disconnect this device")
    }

    var disconnectMessage: String {
        #if os(macOS)
        String(localized: "This Mac stops syncing with \(name). Your playlists and history stay here, and \(name) keeps its copy.")
        #else
        String(localized: "This iPhone stops syncing with \(name). Your playlists and history stay here, and \(name) keeps its copy.")
        #endif
    }

    var thisDeviceLabel: String {
        #if os(macOS)
        String(localized: "This Mac")
        #else
        String(localized: "This iPhone")
        #endif
    }

    func start() {
        let center = NotificationCenter.default
        let names = [
            FlaccyServerStatusStore.didChange, RemoteServers.didChange, PurchaseManager.stateDidChange,
            PurchaseManager.entitlementsDidLoad,
        ]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reloadRecord() }
            })
        }
        Task { await loadDevices() }
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    func loadDevices() async {
        do {
            let listed = try await engine.devices()
            devices = .loaded(listed.map(row(for:)))
            FlaccyServerStatusStore.shared.noteDevices(count: listed.count)
        } catch {
            devices = .failed(Self.devicesFailure(error, server: name))
        }
        onChange?()
    }

    func setLibraryShown(_ shown: Bool) async throws {
        try await RemoteLibraryVisibility.setShown(shown, serverID: serverID)
        onChange?()
    }

    /// Turns syncing on or off. Without Pro the switch is a door to the paywall and nothing changes.
    func setSyncOn(_ on: Bool) async {
        guard isPro else {
            onProRequested?()
            return
        }
        await engine.setPaused(!on)
        onChange?()
    }

    func rename(device: DeviceRow, to newName: String) async throws {
        try await engine.renameDevice(id: device.id, name: newName)
        await loadDevices()
    }

    func remove(device: DeviceRow) async throws {
        try await engine.removeDevice(id: device.id)
        await loadDevices()
    }

    /// Stops syncing with the server. The server, its data, this device's playlists and history, and the music in the library
    /// stay as they are.
    func disconnect() async throws {
        try await engine.disconnect()
        ServerMergeReporter.shared.cancel()
        FlaccyServerStatusStore.shared.forgetServer()
        MidgarLog.info("Disconnected from \(name)", category: .sync)
    }

    private func reloadRecord() {
        if let record = try? DatabaseManager.shared.fetchRemoteServer(id: serverID) {
            name = record.name
            address = Self.displayAddress(record.baseURL)
        }
        onChange?()
    }

    private func row(for device: ServerDevice) -> DeviceRow {
        DeviceRow(
            id: device.id, name: device.name, isCurrent: device.current,
            lastSeen: device.current ? nil : Self.lastSeen(device.lastSeenAt)
        )
    }

    nonisolated static func lastSeen(_ milliseconds: Int64?, now: Date = Date()) -> String {
        guard let milliseconds else { return String(localized: "Never seen") }
        let seen = Date(timeIntervalSince1970: Double(milliseconds) / 1000)
        if now.timeIntervalSince(seen) < 60 { return String(localized: "Active now") }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return String(localized: "Last seen \(formatter.localizedString(for: seen, relativeTo: now))")
    }

    nonisolated static func devicesFailure(_ error: any Error, server: String) -> String {
        if let failure = error as? ServerSyncError, failure.isUnreachable {
            return String(localized: "Can't reach \(server) to list its devices. Is Tailscale on?")
        }
        return String(localized: "Couldn't list the devices on \(server). Pull down to try again.")
    }

    private static func displayAddress(_ baseURL: String) -> String {
        guard let url = URL(string: baseURL), let host = url.host(percentEncoded: false) else { return baseURL }
        return url.port.map { "\(host):\($0)" } ?? host
    }
}
