import FlaccyCore
import FlaccyServerCore
import Foundation

typealias CoreMutation = FlaccyServerCore.Mutation
typealias CorePending = FlaccyServerCore.PendingMutation
typealias CorePlaylistDoc = FlaccyServerCore.PlaylistDoc
typealias CorePlaylist = FlaccyServerCore.Playlist
typealias CoreEntry = FlaccyServerCore.Entry
typealias CoreLove = FlaccyServerCore.Love
typealias CoreScalar = FlaccyServerCore.Scalar
typealias CoreCaller = FlaccyServerCore.Caller
typealias CoreJSON = FlaccyServerCore.JSONValue
typealias CoreSongRef = FlaccyServerCore.SongRef

/// Bridges the pure wire types of FlaccyCore and the documents the Rust core folds and applies.
enum ServerCoreBridge {

    static let encoder = JSONEncoder()
    static let decoder = JSONDecoder()

    static func json<T: Encodable>(_ value: T) throws -> ServerJSON {
        try decoder.decode(ServerJSON.self, from: encoder.encode(value))
    }

    static func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        try decoder.decode(type, from: Data(text.utf8))
    }

    static func text<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    static func pending(
        id: Int64, name: String, stamp: Int64, argsJSON: String, failed: Bool
    ) throws -> CorePending {
        let args = try decode(CoreJSON.self, from: argsJSON)
        return CorePending(mutation: CoreMutation(id: id, name: name, stamp: stamp, args: args), failed: failed)
    }

    static func nextStamp(last: Int64, offsetMs: Int64, nowMs: Int64) throws -> Int64 {
        try ServerCore.nextStamp(last: last, offsetMs: offsetMs, nowMs: nowMs)
    }

    static func songKey(artistKey: String, titleKey: String) throws -> String {
        try ServerCore.songKey(artistKey: artistKey, titleKey: titleKey)
    }

    static func songKeys(_ pairs: [(artistKey: String, titleKey: String)]) throws -> [String] {
        guard !pairs.isEmpty else { return [] }
        return try ServerCore.songKeys(pairs)
    }

    static func songRef(_ core: CoreSongRef) -> ServerSongRef {
        ServerSongRef(
            songKey: core.songKey, title: core.title, artist: core.artist, album: core.album,
            durationMs: core.durationMs, fp: core.fp, mbid: core.mbid, albumKey: core.albumKey, relPath: core.relPath
        )
    }

    /// The `state.reseed` entities split the way the server accepts them, by the core's own rule.
    static func chunkReseed(_ entities: [ServerJSON]) throws -> [[ServerJSON]] {
        guard !entities.isEmpty else { return [] }
        let typed = try decoder.decode([FlaccyServerCore.Entity].self, from: encoder.encode(entities))
        let chunks = try ServerCore.chunkReseed(typed)
        return try decoder.decode([[ServerJSON]].self, from: encoder.encode(chunks))
    }

    static func eventIdRec(deviceId: String, instance: String, counter: UInt64) throws -> String {
        try ServerCore.eventIdRec(deviceId: deviceId, instance: instance, counter: counter)
    }

    static func eventIdsMig(_ plays: [(ts: Int64, titleKey: String, artistKey: String)]) throws -> [String] {
        guard !plays.isEmpty else { return [] }
        return try ServerCore.eventIdsMig(plays)
    }

    static func playlistId(name: String, occurrence: UInt32) throws -> String {
        try ServerCore.playlistId(name: name, occurrence: occurrence)
    }

    static func entryId(playlistId: String, songKey: String, occurrence: UInt32) throws -> String {
        try ServerCore.entryId(playlistId: playlistId, songKey: songKey, occurrence: occurrence)
    }

    static func normalizePlaylistName(_ name: String) throws -> String {
        try ServerCore.normalizePlaylistName(name)
    }

    static func rebasePlaylist(id: String, base: CorePlaylistDoc?, caller: CoreCaller, pending: [CorePending]) throws -> CorePlaylistDoc? {
        try ServerCore.rebasePlaylist(id: id, base: base, caller: caller, pending: pending)
    }

    static func rebaseLove(songKey: String, base: CoreLove?, caller: CoreCaller, pending: [CorePending]) throws -> CoreLove? {
        try ServerCore.rebaseLove(songKey: songKey, base: base, caller: caller, pending: pending)
    }

    static func rebaseScalar(key: String, base: CoreScalar?, caller: CoreCaller, pending: [CorePending]) throws -> CoreScalar? {
        try ServerCore.rebaseScalar(key: key, base: base, caller: caller, pending: pending)
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
