import FlaccyCore
import FlaccyServerCore
import Foundation

@testable import FlaccyEngine

/// A Flaccy Server in memory, speaking the transport the engine calls. Playlist and scalar mutations run through the same Rust
/// core the real server uses; the rest of the bookkeeping (progress per instance, retry hashes, gaps, incarnation, cursors) follows
/// PROTOCOL.md section 6. Knobs let a test drop the network, lose a response, restore the server from an older state or refuse writes.
final class FakeFlaccyServer: @unchecked Sendable {

    struct Row {
        var seq: Int64
        var kind: String
        var id: String
        var deleted: Bool
        var value: ServerJSON
    }

    struct Play {
        var item: ServerListenItem
        var titleKey: String
        var artistKey: String
    }

    struct State {
        var incarnation: String
        var seq: Int64 = 0
        var hlc: Int64 = 0
        var rows: [String: Row] = [:]
        var playlists: [String: CorePlaylistDoc] = [:]
        var loves: [String: CoreLove] = [:]
        var scalars: [String: CoreScalar] = [:]
        var plays: [String: Play] = [:]
        var progress: [String: Int64] = [:]
        var results: [String: (hash: String, result: ServerMutationResult)] = [:]
        var blobs: [String: Data] = [:]
    }

    let lock = NSLock()
    var state: State
    var tokens: [String: (device: String, user: String)] = [:]
    var deviceNames: [String: String] = [:]
    var codes: Set<String> = ["GOODCODE"]
    var counter = 0
    var clock: @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }

    var online = true
    var noNetwork = false
    var queuedFailures: [ServerSyncError] = []
    var dropNextPushResponse = false
    var queuedPushFailures: [ServerSyncError] = []
    var pullSinces: [Int64] = []
    var pageCap = 5_000
    var refusedNames: Set<String> = []
    var role: ServerRole = .member
    var writeRole: ServerRole = .member
    var queuedHelloRoles: [ServerRole] = []
    var refuseCoversTimes = 0
    var protocols = [1]
    var features = ["sync", "live", "lastfm.history"]
    var oversizedPageOnce = false
    var calls: [String] = []
    var pushes: [ServerPushRequest] = []

    init() {
        state = State(incarnation: ServerSyncIDs.uuidV7(nowMs: 1))
    }

    var incarnation: String { locked { state.incarnation } }
    var seq: Int64 { locked { state.seq } }

    func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    func snapshot() -> State { locked { state } }

    func restore(_ saved: State, newIncarnation: Bool) {
        locked {
            let incarnation = newIncarnation ? ServerSyncIDs.uuidV7(nowMs: clock()) : state.incarnation
            state = saved
            state.incarnation = incarnation
        }
    }

    func forgetProgress() {
        locked {
            state.progress = [:]
            state.results = [:]
        }
    }

    func transport(token: String?) -> FakeTransport {
        FakeTransport(server: self, token: token)
    }

    func entity(_ kind: String, _ id: String) -> Row? { locked { state.rows["\(kind)/\(id)"] } }
    func playlist(named name: String) -> CorePlaylistDoc? { locked { state.playlists.values.first { $0.playlist.name == name } } }
    func callCount(_ name: String) -> Int { locked { calls.filter { $0 == name }.count } }
    func lastPush() -> ServerPushRequest? { locked { pushes.last } }
    func allPushes() -> [ServerPushRequest] { locked { pushes } }
    func visiblePlays() -> [ServerListenItem] { locked { state.plays.values.map(\.item).filter { !$0.suppressed } } }
    func setBlob(_ hash: String, _ data: Data) { locked { state.blobs[hash] = data } }

    func plantScalar(_ key: String, _ value: ServerJSON?, stamp: Int64) throws {
        try locked {
            let scalar = CoreScalar(
                key: key, value: try ServerCoreBridge.decode(CoreJSON.self, from: value?.text ?? "null"),
                deleted: value == nil, stamp: stamp
            )
            state.scalars[key] = scalar
            try emit("scalar", key, deleted: scalar.deleted, value: scalar)
        }
    }

    func plantLove(_ song: ServerSongRef, loved: Bool, stamp: Int64) throws {
        try locked {
            let love = CoreLove(songKey: song.songKey, song: coreRef(song), loved: loved, stamp: stamp)
            state.loves[song.songKey] = love
            try emit("love", song.songKey, deleted: !loved, value: love)
        }
    }

    @discardableResult
    func plantPlaylist(name: String, songs: [ServerSongRef], coverBlob: String? = nil) throws -> String {
        try locked {
            counter += 1
            let id = ServerSyncIDs.uuidV7(nowMs: Int64(counter))
            let playlist = CorePlaylist(
                id: id, owner: "user-1", name: name, coverBlob: coverBlob, visibility: .private, alive: true, createdAt: 1_700_000_000,
                stamps: PlaylistStamps(name: 1, cover: 1, visibility: 1, alive: 1)
            )
            var entries: [CoreEntry] = []
            for (index, song) in songs.enumerated() {
                entries.append(CoreEntry(
                    id: ServerSyncIDs.uuidV7(nowMs: Int64(counter * 10_000 + index)), playlist: id, song: coreRef(song),
                    pos: "a\(String(format: "%05d", index))V", alive: true, stamps: EntryStamps(song: 1, pos: 1, alive: 1)
                ))
            }
            state.playlists[id] = CorePlaylistDoc(playlist: playlist, entries: entries)
            try emit("playlist", id, deleted: false, value: playlist)
            for entry in entries { try emit("playlist_entry", entry.id, deleted: false, value: entry) }
            return id
        }
    }

    func plantSessions(_ count: Int) throws {
        try locked {
            for index in 0..<count {
                let session: ServerJSON = ["device": .string("device-\(index)"), "session": ["queue": []], "stamp": .int(Int64(index + 1))]
                try emit("session", "device-\(index)", deleted: false, value: session)
            }
        }
    }

    func plantPlay(_ item: ServerListenItem) {
        locked {
            var item = item
            state.seq += 1
            item.seq = state.seq
            state.plays[item.eventId] = Play(
                item: item, titleKey: ListenHistory.titleKey(item.ref.title), artistKey: ListenHistory.artistKey(item.ref.artist)
            )
        }
    }

    func coreRef(_ song: ServerSongRef) -> CoreSongRef {
        CoreSongRef(
            songKey: song.songKey, title: song.title, artist: song.artist, album: song.album, durationMs: song.durationMs,
            fp: song.fp, mbid: song.mbid, albumKey: song.albumKey, relPath: song.relPath
        )
    }

    func gate(_ name: String) throws {
        calls.append(name)
        if !online { throw noNetwork ? ServerSyncError.noNetwork : ServerSyncError.offline("down") }
        if !queuedFailures.isEmpty { throw queuedFailures.removeFirst() }
    }

    func authenticate(_ token: String?) throws -> (device: String, user: String) {
        guard let token, let who = tokens[token] else { throw ServerSyncError.unauthorized }
        return who
    }

    func checkIncarnation(_ claimed: String?) throws {
        if let claimed, claimed != state.incarnation { throw ServerSyncError.incarnationChanged(state.incarnation) }
    }

    func hello(token: String?) throws -> ServerHello {
        try locked {
            try gate("hello")
            var caller: ServerHelloCaller?
            if let token, let who = tokens[token] {
                let shown = queuedHelloRoles.isEmpty ? role : queuedHelloRoles.removeFirst()
                caller = ServerHelloCaller(user: who.user, role: shown, device: who.device)
            }
            return ServerHello(
                protocols: protocols, server: ServerInfo(name: "fake", version: "1.0.0", schema: 1), features: features,
                mode: "easy", serverTimeMs: clock(), incarnation: state.incarnation, caller: caller
            )
        }
    }

    func enroll(_ request: ServerEnrollRequest) throws -> ServerEnrollReply {
        try locked {
            try gate("enroll")
            guard codes.remove(request.enroll) != nil else { throw ServerSyncError.enrollInvalid }
            counter += 1
            let token = "token-\(counter)"
            let device = "device-\(counter)"
            tokens[token] = (device, "user-1")
            deviceNames[device] = request.name
            return ServerEnrollReply(
                device: device, token: token, user: ServerUser(id: "user-1", name: "tester", role: role),
                serverTimeMs: clock(), incarnation: state.incarnation
            )
        }
    }

    func newCode(_ code: String) { locked { _ = codes.insert(code) } }

    func devices(token: String?) throws -> [ServerDevice] {
        try locked {
            try gate("devices")
            let me = try authenticate(token)
            return deviceNames.sorted { $0.key < $1.key }.map {
                ServerDevice(id: $0.key, userId: "user-1", name: $0.value, platform: "ios", current: $0.key == me.device)
            }
        }
    }

    func rename(device: String, name: String, token: String?) throws {
        try locked {
            try gate("renameDevice")
            _ = try authenticate(token)
            deviceNames[device] = name
        }
    }

    func revoke(device: String, token: String?) throws {
        try locked {
            try gate("revokeDevice")
            _ = try authenticate(token)
            deviceNames[device] = nil
            tokens = tokens.filter { $0.value.device != device }
        }
    }

    func revokeAll() { locked { tokens = [:] } }

    func put(blob hash: String, data: Data, token: String?) throws {
        try locked {
            try gate("putBlob")
            _ = try authenticate(token)
            state.blobs[hash] = data
        }
    }

    func blob(hash: String, token: String?) throws -> Data {
        try locked {
            try gate("blob")
            _ = try authenticate(token)
            guard let data = state.blobs[hash] else { throw ServerSyncError.refused(status: 404, code: "not_found") }
            return data
        }
    }

    func emit<T: Encodable>(_ kind: String, _ id: String, deleted: Bool, value: T) throws {
        state.seq += 1
        state.rows["\(kind)/\(id)"] = Row(seq: state.seq, kind: kind, id: id, deleted: deleted, value: try ServerCoreBridge.json(value))
    }

    func nextStored(_ clientStamp: Int64) -> Int64 {
        state.hlc = max(clock() << 16, state.hlc + 1)
        return min(clientStamp, state.hlc)
    }
}
