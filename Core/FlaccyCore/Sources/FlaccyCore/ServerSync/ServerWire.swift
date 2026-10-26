import Foundation

public enum ServerRole: String, Hashable, Sendable, Codable {
    case admin
    case member
    case guest
    case pending
}

public struct ServerInfo: Hashable, Sendable, Codable {
    public var name: String
    public var version: String
    public var schema: Int

    public init(name: String, version: String, schema: Int) {
        self.name = name
        self.version = version
        self.schema = schema
    }
}

public struct ServerHelloCaller: Hashable, Sendable, Codable {
    public var user: String
    public var role: ServerRole
    public var device: String?

    public init(user: String, role: ServerRole, device: String?) {
        self.user = user
        self.role = role
        self.device = device
    }
}

/// `GET /hello`.
public struct ServerHello: Hashable, Sendable, Codable {
    public var protocols: [Int]
    public var server: ServerInfo
    public var features: [String]
    public var mode: String
    public var serverTimeMs: Int64
    public var incarnation: String
    public var caller: ServerHelloCaller?

    public init(
        protocols: [Int], server: ServerInfo, features: [String], mode: String, serverTimeMs: Int64,
        incarnation: String, caller: ServerHelloCaller? = nil
    ) {
        self.protocols = protocols
        self.server = server
        self.features = features
        self.mode = mode
        self.serverTimeMs = serverTimeMs
        self.incarnation = incarnation
        self.caller = caller
    }

    private enum CodingKeys: String, CodingKey {
        case protocols = "protocol"
        case server, features, mode, serverTimeMs, incarnation, caller
    }
}

public struct ServerEnrollRequest: Hashable, Sendable, Codable {
    public var enroll: String
    public var name: String
    public var platform: String
    public var instance: String

    public init(enroll: String, name: String, platform: String, instance: String) {
        self.enroll = enroll
        self.name = name
        self.platform = platform
        self.instance = instance
    }
}

public struct ServerUser: Hashable, Sendable, Codable {
    public var id: String
    public var name: String
    public var role: ServerRole

    public init(id: String, name: String, role: ServerRole) {
        self.id = id
        self.name = name
        self.role = role
    }
}

/// `POST /devices`. The token is a secret: keep it in the Keychain only.
public struct ServerEnrollReply: Sendable, Codable, CustomStringConvertible {
    public var device: String
    public var token: String
    public var user: ServerUser
    public var serverTimeMs: Int64
    public var incarnation: String

    public init(device: String, token: String, user: ServerUser, serverTimeMs: Int64, incarnation: String) {
        self.device = device
        self.token = token
        self.user = user
        self.serverTimeMs = serverTimeMs
        self.incarnation = incarnation
    }

    public var description: String {
        "ServerEnrollReply(device: \(device), user: \(user.id), token: ***)"
    }
}

/// One device of the signed-in person, as `GET /devices` lists it.
public struct ServerDevice: Hashable, Sendable, Codable, Identifiable {
    public var id: String
    public var userId: String
    public var name: String
    public var platform: String
    public var createdAt: Int64?
    public var lastSeenAt: Int64?
    public var revokedAt: Int64?
    public var current: Bool

    public init(
        id: String, userId: String, name: String, platform: String, createdAt: Int64? = nil,
        lastSeenAt: Int64? = nil, revokedAt: Int64? = nil, current: Bool = false
    ) {
        self.id = id
        self.userId = userId
        self.name = name
        self.platform = platform
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
        self.revokedAt = revokedAt
        self.current = current
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        userId = try container.decodeIfPresent(String.self, forKey: .userId) ?? ""
        name = try container.decode(String.self, forKey: .name)
        platform = try container.decodeIfPresent(String.self, forKey: .platform) ?? "other"
        createdAt = try container.decodeIfPresent(Int64.self, forKey: .createdAt)
        lastSeenAt = try container.decodeIfPresent(Int64.self, forKey: .lastSeenAt)
        revokedAt = try container.decodeIfPresent(Int64.self, forKey: .revokedAt)
        current = try container.decodeIfPresent(Bool.self, forKey: .current) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case id, userId, name, platform, createdAt, lastSeenAt, revokedAt, current
    }
}

public struct ServerDevicesReply: Hashable, Sendable, Codable {
    public var devices: [ServerDevice]
}

/// One client write: a dense per-instance id, a stamp, a name and its arguments.
public struct ServerMutation: Hashable, Sendable, Codable {
    public var id: Int64
    public var name: String
    public var stamp: Int64
    public var args: ServerJSON

    public init(id: Int64, name: String, stamp: Int64, args: ServerJSON) {
        self.id = id
        self.name = name
        self.stamp = stamp
        self.args = args
    }
}

public struct ServerPushRequest: Hashable, Sendable, Codable {
    public var device: String
    public var instance: String
    public var mutations: [ServerMutation]

    public init(device: String, instance: String, mutations: [ServerMutation]) {
        self.device = device
        self.instance = instance
        self.mutations = mutations
    }
}

public enum ServerMutationStatus: Hashable, Sendable, Codable {
    case applied
    case noop
    case invalid
    case unsupported

    public init(from decoder: any Decoder) throws {
        let word = try decoder.singleValueContainer().decode(String.self)
        switch word {
        case "applied": self = .applied
        case "noop": self = .noop
        case "invalid": self = .invalid
        default: self = .unsupported
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .applied: try container.encode("applied")
        case .noop: try container.encode("noop")
        case .invalid: try container.encode("invalid")
        case .unsupported: try container.encode("unsupported")
        }
    }

    public var isRefusal: Bool { self == .invalid || self == .unsupported }
}

public struct ServerMutationResult: Hashable, Sendable, Codable {
    public var id: Int64
    public var status: ServerMutationStatus
    public var code: String?

    public init(id: Int64, status: ServerMutationStatus, code: String? = nil) {
        self.id = id
        self.status = status
        self.code = code
    }
}

public struct ServerPushResponse: Hashable, Sendable, Codable {
    public var results: [ServerMutationResult]
    public var serverTimeMs: Int64

    public init(results: [ServerMutationResult], serverTimeMs: Int64) {
        self.results = results
        self.serverTimeMs = serverTimeMs
    }
}

/// One entry of a pull: an entity's full current value at a sequence number.
public struct ServerChange: Hashable, Sendable, Codable {
    public var seq: Int64
    public var kind: ServerEntityKind
    public var id: String
    public var deleted: Bool
    public var value: ServerJSON

    public init(seq: Int64, kind: ServerEntityKind, id: String, deleted: Bool, value: ServerJSON) {
        self.seq = seq
        self.kind = kind
        self.id = id
        self.deleted = deleted
        self.value = value
    }
}

/// `GET /sync/pull`.
public struct ServerPullResponse: Hashable, Sendable, Codable {
    public var head: Int64
    public var incarnation: String
    public var lastMutationId: Int64
    public var more: Bool
    public var serverTimeMs: Int64
    public var changes: [ServerChange]

    public init(
        head: Int64, incarnation: String, lastMutationId: Int64, more: Bool, serverTimeMs: Int64,
        changes: [ServerChange]
    ) {
        self.head = head
        self.incarnation = incarnation
        self.lastMutationId = lastMutationId
        self.more = more
        self.serverTimeMs = serverTimeMs
        self.changes = changes
    }
}

/// One listen as `GET /listens` returns it.
public struct ServerListenItem: Hashable, Sendable, Codable {
    public var seq: Int64
    public var eventId: String
    public var ts: Int64
    public var ref: ServerSongRef
    public var playedS: Int64
    public var source: ServerListenSource?
    public var recorded: Bool
    public var device: String?
    public var suppressed: Bool

    public init(
        seq: Int64, eventId: String, ts: Int64, ref: ServerSongRef, playedS: Int64,
        source: ServerListenSource? = nil, recorded: Bool = true, device: String? = nil, suppressed: Bool = false
    ) {
        self.seq = seq
        self.eventId = eventId
        self.ts = ts
        self.ref = ref
        self.playedS = playedS
        self.source = source
        self.recorded = recorded
        self.device = device
        self.suppressed = suppressed
    }

    private enum CodingKeys: String, CodingKey {
        case seq, eventId, ts, ref, playedS, source, recorded, device, suppressed
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        seq = try container.decode(Int64.self, forKey: .seq)
        eventId = try container.decode(String.self, forKey: .eventId)
        ts = try container.decode(Int64.self, forKey: .ts)
        ref = try container.decode(ServerSongRef.self, forKey: .ref)
        playedS = try container.decodeIfPresent(Int64.self, forKey: .playedS) ?? 0
        source = try? container.decodeIfPresent(ServerListenSource.self, forKey: .source)
        recorded = try container.decodeIfPresent(Bool.self, forKey: .recorded) ?? true
        device = try container.decodeIfPresent(String.self, forKey: .device)
        suppressed = try container.decodeIfPresent(Bool.self, forKey: .suppressed) ?? false
    }
}

public struct ServerListensPage: Hashable, Sendable, Codable {
    public var listens: [ServerListenItem]
    public var more: Bool
    public var head: Int64

    public init(listens: [ServerListenItem], more: Bool, head: Int64) {
        self.listens = listens
        self.more = more
        self.head = head
    }

    private enum CodingKeys: String, CodingKey {
        case listens, more, head
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        listens = try container.decode([ServerListenItem].self, forKey: .listens)
        more = try container.decodeIfPresent(Bool.self, forKey: .more) ?? false
        head = try container.decodeIfPresent(Int64.self, forKey: .head) ?? 0
    }
}

/// The body of an error answer: `{"error": {"code", "message", "hint"?, "incarnation"?, "have"?}}`.
public struct ServerErrorBody: Hashable, Sendable, Codable {
    public struct Detail: Hashable, Sendable, Codable {
        public var code: String
        public var message: String?
        public var hint: String?
        public var incarnation: String?
        public var have: Int64?
    }

    public var error: Detail
    public var incarnation: String?
    public var have: Int64?
}
