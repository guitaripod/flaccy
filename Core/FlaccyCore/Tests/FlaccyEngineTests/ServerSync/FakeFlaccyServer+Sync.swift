import FlaccyCore
import FlaccyServerCore
import Foundation

@testable import FlaccyEngine

extension FakeFlaccyServer {

    private static let sortedEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private func hash(of mutation: ServerMutation) -> String {
        let args = (try? Self.sortedEncoder.encode(mutation.args)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        return mutation.name + "|" + args
    }

    func push(_ request: ServerPushRequest, incarnation claimed: String?, token: String?) throws -> ServerPushResponse {
        try locked {
            try gate("push")
            if !queuedPushFailures.isEmpty { throw queuedPushFailures.removeFirst() }
            let who = try authenticate(token)
            try checkIncarnation(claimed)
            pushes.append(request)
            let key = "\(request.device)|\(request.instance)"
            let last = state.progress[key] ?? 0
            for mutation in request.mutations where mutation.id <= last {
                guard state.results["\(key)|\(mutation.id)"]?.hash == hash(of: mutation) else {
                    throw ServerSyncError.instanceConflict
                }
            }
            var expected = last + 1
            for mutation in request.mutations where mutation.id > last {
                guard mutation.id == expected else { throw ServerSyncError.mutationGap(have: last) }
                expected += 1
            }
            var results: [ServerMutationResult] = []
            for mutation in request.mutations {
                if mutation.id <= last, let stored = state.results["\(key)|\(mutation.id)"] {
                    results.append(stored.result)
                    continue
                }
                let result = try apply(mutation, caller: CoreCaller(user: who.user, role: .member, device: who.device))
                state.results["\(key)|\(mutation.id)"] = (hash(of: mutation), result)
                state.progress[key] = mutation.id
                results.append(result)
            }
            if dropNextPushResponse {
                dropNextPushResponse = false
                throw ServerSyncError.offline("the response was lost")
            }
            return ServerPushResponse(results: results, serverTimeMs: clock())
        }
    }

    private func apply(_ mutation: ServerMutation, caller: CoreCaller) throws -> ServerMutationResult {
        let id = mutation.id
        if refusedNames.contains(mutation.name) {
            return ServerMutationResult(id: id, status: .invalid, code: "bad_args")
        }
        let stamp = nextStored(mutation.stamp)
        let core = CoreMutation(id: id, name: mutation.name, stamp: mutation.stamp, args: try ServerCoreBridge.decode(CoreJSON.self, from: mutation.args.text ?? "null"))
        switch mutation.name {
        case "playlist.create", "playlist.rename", "playlist.setCover", "playlist.clearCover", "playlist.delete",
             "playlist.restore", "playlist.setVisibility", "entry.insert", "entry.insertMany", "entry.move", "entry.remove":
            return try applyPlaylist(core, mutation, caller: caller, stamp: stamp)
        case "love.set":
            return try applyLove(mutation, stamp: stamp)
        case "scalar.set", "scalar.clear":
            let key = mutation.args["key"]?.string ?? ""
            let result = try ServerCore.applyScalar(scalar: state.scalars[key], mutation: core, caller: caller, stamp: stamp)
            if result.status == .applied, let scalar = result.scalar {
                state.scalars[key] = scalar
                try emit("scalar", key, deleted: scalar.deleted, value: scalar)
            }
            return ServerMutationResult(id: id, status: Self.status(result.status), code: result.code?.rawValue)
        case "listen.record":
            try recordListens(mutation, device: caller.device)
            return ServerMutationResult(id: id, status: .applied)
        case "state.reseed":
            try reseed(mutation, stamp: stamp)
            return ServerMutationResult(id: id, status: .applied)
        case "session.save", "device.rename":
            return ServerMutationResult(id: id, status: .noop)
        default:
            return ServerMutationResult(id: id, status: .unsupported)
        }
    }

    private static func status(_ status: ApplyStatus) -> ServerMutationStatus {
        switch status {
        case .applied: .applied
        case .noop: .noop
        case .invalid: .invalid
        case .unsupported: .unsupported
        }
    }

    private func applyPlaylist(
        _ core: CoreMutation, _ mutation: ServerMutation, caller: CoreCaller, stamp: Int64
    ) throws -> ServerMutationResult {
        let targetID: String
        switch mutation.name {
        case "entry.insert", "entry.insertMany": targetID = mutation.args["playlist"]?.string ?? ""
        case "entry.move", "entry.remove":
            let entry = mutation.args["id"]?.string ?? ""
            targetID = state.playlists.first { $0.value.entries.contains { $0.id == entry } }?.key ?? ""
        default: targetID = mutation.args["id"]?.string ?? ""
        }
        let result = try ServerCore.applyPlaylist(doc: state.playlists[targetID], mutation: core, caller: caller, stamp: stamp)
        guard result.status == .applied, let doc = result.doc else {
            return ServerMutationResult(id: mutation.id, status: Self.status(result.status), code: result.code?.rawValue)
        }
        state.playlists[doc.playlist.id] = doc
        for changed in result.changed {
            switch changed.kind {
            case .playlist: try emit("playlist", doc.playlist.id, deleted: !doc.playlist.alive, value: doc.playlist)
            case .playlistEntry:
                if let entry = doc.entries.first(where: { $0.id == changed.id }) {
                    try emit("playlist_entry", entry.id, deleted: !entry.alive, value: entry)
                }
            default: break
            }
        }
        return ServerMutationResult(id: mutation.id, status: .applied)
    }

    private func applyLove(_ mutation: ServerMutation, stamp: Int64) throws -> ServerMutationResult {
        let args = try ServerCoreBridge.decode(LoveArgs.self, from: mutation.args.text ?? "{}")
        if let existing = state.loves[args.songKey], existing.stamp > stamp {
            return ServerMutationResult(id: mutation.id, status: .noop)
        }
        let love = CoreLove(songKey: args.songKey, song: args.ref, loved: args.loved, stamp: stamp)
        state.loves[args.songKey] = love
        try emit("love", args.songKey, deleted: !love.loved, value: love)
        return ServerMutationResult(id: mutation.id, status: .applied)
    }

    private struct LoveArgs: Decodable {
        var songKey: String
        var ref: CoreSongRef
        var loved: Bool
    }

    private func recordListens(_ mutation: ServerMutation, device: String) throws {
        guard let listens = mutation.args["listens"]?.array else { return }
        var seconds = Set<Int64>()
        for listen in listens {
            let input = try ServerCoreBridge.decode(ServerListenInput.self, from: listen.text ?? "{}")
            if state.plays[input.eventId] != nil { continue }
            state.seq += 1
            let item = ServerListenItem(
                seq: state.seq, eventId: input.eventId, ts: input.ts, ref: input.ref, playedS: input.playedS,
                source: .flaccy, recorded: input.recorded, device: device
            )
            state.plays[input.eventId] = Play(
                item: item, titleKey: ListenHistory.titleKey(input.ref.title), artistKey: ListenHistory.artistKey(input.ref.artist)
            )
            seconds.insert(input.ts)
        }
        for second in seconds { try runLedger(second) }
    }

    func runLedger(_ second: Int64) throws {
        let plays = state.plays.values.filter { $0.item.ts == second }.sorted { $0.item.eventId < $1.item.eventId }
        let events = plays.map {
            SecondEvent(
                eventId: $0.item.eventId, recorded: $0.item.recorded, titleKey: $0.titleKey, artistKey: $0.artistKey,
                suppressed: $0.item.suppressed
            )
        }
        let flags = try ServerCore.suppressedFlags(events)
        for (play, flag) in zip(plays, flags) where play.item.suppressed != flag {
            state.seq += 1
            let seq = state.seq
            state.plays[play.item.eventId]?.item.suppressed = flag
            state.plays[play.item.eventId]?.item.seq = seq
        }
    }

    private func reseed(_ mutation: ServerMutation, stamp: Int64) throws {
        for entity in mutation.args["entities"]?.array ?? [] {
            guard let kind = entity["kind"]?.string, let id = entity["id"]?.string, let value = entity["value"],
                  let text = value.text else { continue }
            switch kind {
            case "playlist":
                let playlist = try ServerCoreBridge.decode(CorePlaylist.self, from: text)
                guard state.playlists[id] == nil else { continue }
                state.playlists[id] = CorePlaylistDoc(playlist: playlist, entries: [])
                try emit("playlist", id, deleted: !playlist.alive, value: playlist)
            case "playlist_entry":
                let entry = try ServerCoreBridge.decode(CoreEntry.self, from: text)
                guard var doc = state.playlists[entry.playlist], !doc.entries.contains(where: { $0.id == id }) else { continue }
                doc.entries.append(entry)
                state.playlists[entry.playlist] = doc
                try emit("playlist_entry", id, deleted: !entry.alive, value: entry)
            case "love":
                let love = try ServerCoreBridge.decode(CoreLove.self, from: text)
                guard (state.loves[id]?.stamp ?? 0) <= love.stamp else { continue }
                state.loves[id] = love
                try emit("love", id, deleted: !love.loved, value: love)
            case "scalar":
                let scalar = try ServerCoreBridge.decode(CoreScalar.self, from: text)
                guard (state.scalars[id]?.stamp ?? 0) <= scalar.stamp else { continue }
                state.scalars[id] = scalar
                try emit("scalar", id, deleted: scalar.deleted, value: scalar)
            default: continue
            }
        }
    }

    func pull(since: Int64, limit: Int, instance: String, incarnation claimed: String?, token: String?) throws -> ServerPullResponse {
        try locked {
            try gate("pull")
            pullSinces.append(since)
            let who = try authenticate(token)
            try checkIncarnation(claimed)
            if since > state.seq { throw ServerSyncError.cookieAhead(state.incarnation) }
            let all = state.rows.values.filter { $0.seq > since }.sorted { $0.seq < $1.seq }
            var take = min(limit, pageCap)
            if oversizedPageOnce {
                oversizedPageOnce = false
                take = all.count
            }
            let page = Array(all.prefix(take))
            let changes = page.map { ServerChange(seq: $0.seq, kind: ServerEntityKind.named($0.kind), id: $0.id, deleted: $0.deleted, value: $0.value) }
            return ServerPullResponse(
                head: state.seq, incarnation: state.incarnation, lastMutationId: state.progress["\(who.device)|\(instance)"] ?? 0,
                more: all.count > page.count, serverTimeMs: clock(), changes: changes
            )
        }
    }

    func listens(before: Int64?, after: Int64?, limit: Int, incarnation claimed: String?, token: String?) throws -> ServerListensPage {
        try locked {
            try gate("listens")
            _ = try authenticate(token)
            try checkIncarnation(claimed)
            if let after, after > state.seq { throw ServerSyncError.cookieAhead(state.incarnation) }
            let items = state.plays.values.map(\.item)
            let ordered: [ServerListenItem]
            if let after {
                ordered = items.filter { $0.seq > after }.sorted { $0.seq < $1.seq }
            } else {
                ordered = items.filter { $0.ts < (before ?? Int64.max) }.sorted { $0.ts > $1.ts }
            }
            let page = Array(ordered.prefix(min(limit, pageCap)))
            return ServerListensPage(listens: page, more: ordered.count > page.count, head: items.map(\.seq).max() ?? 0)
        }
    }
}

extension ServerEntityKind {
    static func named(_ name: String) -> ServerEntityKind {
        (try? JSONDecoder().decode(ServerEntityKind.self, from: Data("\"\(name)\"".utf8))) ?? .unknown(name)
    }
}

struct FakeTransport: ServerSyncTransport {
    let server: FakeFlaccyServer
    let token: String?

    func hello() async throws -> ServerHello { try server.hello() }
    func enroll(_ request: ServerEnrollRequest) async throws -> ServerEnrollReply { try server.enroll(request) }
    func push(_ request: ServerPushRequest, incarnation: String?) async throws -> ServerPushResponse {
        try server.push(request, incarnation: incarnation, token: token)
    }
    func pull(since: Int64, limit: Int, instance: String, incarnation: String?) async throws -> ServerPullResponse {
        try server.pull(since: since, limit: limit, instance: instance, incarnation: incarnation, token: token)
    }
    func listens(before: Int64?, after: Int64?, limit: Int, incarnation: String?) async throws -> ServerListensPage {
        try server.listens(before: before, after: after, limit: limit, incarnation: incarnation, token: token)
    }
    func devices() async throws -> [ServerDevice] { try server.devices(token: token) }
    func renameDevice(id: String, name: String) async throws { try server.rename(device: id, name: name, token: token) }
    func revokeDevice(id: String) async throws { try server.revoke(device: id, token: token) }
    func putBlob(hash: String, data: Data, mime: String) async throws { try server.put(blob: hash, data: data, token: token) }
    func blob(hash: String) async throws -> Data { try server.blob(hash: hash, token: token) }
}

struct FakeTransports: ServerSyncTransportFactory {
    let server: FakeFlaccyServer

    func transport(baseURL: URL, token: String?) -> any ServerSyncTransport {
        server.transport(token: token)
    }
}

final class MemoryTokens: ServerTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String: String] = [:]

    func token(serverID: String) -> String? { lock.withLock { tokens[serverID] } }
    func setToken(_ token: String, serverID: String) throws { lock.withLock { tokens[serverID] = token } }
    func removeToken(serverID: String) { lock.withLock { tokens[serverID] = nil } }
    var isEmpty: Bool { lock.withLock { tokens.isEmpty } }
}

final class RecordingSink: ServerScalarSink, @unchecked Sendable {
    private let lock = NSLock()
    private var applied: [(key: String, value: ServerJSON?)] = []

    func apply(key: String, value: ServerJSON?) { lock.withLock { applied.append((key, value)) } }
    var calls: [(key: String, value: ServerJSON?)] { lock.withLock { applied } }
}
