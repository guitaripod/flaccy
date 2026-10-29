import FlaccyCore
import Foundation
import GRDB

/// What the first sync with a server combined, for the one summary sheet after connecting: the playlists that existed on this
/// device and on the server, how many songs the server's loves turned on here, and how many plays it brought into the history.
public struct ServerMergeReport: Sendable, Equatable {
    public var playlistNames: [String] = []
    public var lovesAdded = 0
    public var listensMerged = 0

    public init() {}

    /// True when there is nothing worth telling the person: no combined playlist and no new love.
    public var isEmpty: Bool {
        playlistNames.isEmpty && lovesAdded == 0
    }
}

/// The server this device syncs with, as the screens need it.
public struct ServerSyncServer: Sendable, Equatable {
    public let url: URL
    public let name: String
    public let deviceID: String

    init?(link: ServerSyncLink) {
        guard let url = URL(string: link.serverURL) else { return nil }
        self.url = url
        name = link.serverName
        deviceID = link.device
    }
}

/// What the device held when it connected, kept until the first sync has been read back.
struct ServerMergeProbe: Sendable {
    var playlists: [Int64: String]
    var loved: Set<String>
    var combinedNames: [String]?
    var listens = 0
}

extension ServerSyncStore {

    func mergeProbe() throws -> ServerMergeProbe {
        var playlists: [Int64: String] = [:]
        for record in try database.fetchAllPlaylists() {
            if let id = record.id { playlists[id] = record.name }
        }
        return ServerMergeProbe(playlists: playlists, loved: try database.fetchLovedFileURLs())
    }

    /// The names of the playlists that were on this device before connecting and that the server has too, read from the base the
    /// first complete pull filled. Playlist ids derive from the name, so a playlist of the same name on both sides is one entity.
    func combinedPlaylistNames(_ probe: ServerMergeProbe) throws -> [String] {
        let rows = try database.dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT p.id AS id FROM playlists p
                JOIN sync_base b ON b.kind = 'playlist' AND b.id = p.syncId AND b.deleted = 0
                """)
        }
        let names = rows.compactMap { probe.playlists[$0["id"]] }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func lovedPaths() throws -> Set<String> {
        try database.fetchLovedFileURLs()
    }
}

extension ServerSyncEngine {

    /// What the first sync after connecting combined. Ask after that sync has settled and the server's songs have reached the
    /// library, then call `resolveGhosts()` first, so loves that waited for a song are counted. It answers once and then forgets.
    public func firstConnectMerge() -> ServerMergeReport {
        guard let probe = mergeProbe else { return ServerMergeReport() }
        mergeProbe = nil
        var report = ServerMergeReport()
        report.playlistNames = probe.combinedNames ?? []
        let loved = (try? store.lovedPaths()) ?? probe.loved
        report.lovesAdded = loved.subtracting(probe.loved).count
        report.listensMerged = probe.listens
        return report
    }

    func noteFirstPullComplete() {
        guard var probe = mergeProbe, probe.combinedNames == nil else { return }
        probe.combinedNames = (try? store.combinedPlaylistNames(probe)) ?? []
        mergeProbe = probe
    }

    func noteListensMerged(_ count: Int) {
        guard count > 0, mergeProbe != nil else { return }
        mergeProbe?.listens += count
    }
}
