public enum Role: String, Hashable, Sendable, Codable {
    case admin
    case member
    case guest
    case pending
}

public struct Caller: Hashable, Sendable, Codable {
    public var user: String
    public var role: Role
    public var device: String

    public init(user: String, role: Role = .member, device: String = "") {
        self.user = user
        self.role = role
        self.device = device
    }
}

public struct Mutation: Hashable, Sendable, Codable {
    public var id: Int64
    public var name: String
    public var stamp: Stamp
    public var args: JSONValue

    public init(id: Int64, name: String, stamp: Stamp, args: JSONValue = [:]) {
        self.id = id
        self.name = name
        self.stamp = stamp
        self.args = args
    }
}

public struct PendingMutation: Hashable, Sendable, Codable {
    public var mutation: Mutation
    public var failed: Bool

    public init(mutation: Mutation, failed: Bool = false) {
        self.mutation = mutation
        self.failed = failed
    }
}

public enum ApplyStatus: String, Hashable, Sendable, Codable {
    case applied
    case noop
    case invalid
    case unsupported
}

public enum ErrorCode: String, Hashable, Sendable, Codable {
    case unknownPlaylist = "unknown_playlist"
    case unknownAnchor = "unknown_anchor"
    case badArgs = "bad_args"
    case badKey = "bad_key"
    case forbidden
    case tooLarge = "too_large"
}

public enum EntityKind: String, Hashable, Sendable, Codable {
    case playlist
    case playlistEntry = "playlist_entry"
    case love
    case rating
    case scalar
    case session
    case listen
}

public struct EntityRef: Hashable, Sendable, Codable {
    public var kind: EntityKind
    public var id: String

    public init(kind: EntityKind, id: String) {
        self.kind = kind
        self.id = id
    }
}

public struct Entity: Hashable, Sendable, Codable {
    public var kind: EntityKind
    public var id: String
    public var value: JSONValue

    public init(kind: EntityKind, id: String, value: JSONValue) {
        self.kind = kind
        self.id = id
        self.value = value
    }
}

public struct ApplyPlaylistResult: Hashable, Sendable, Codable {
    public var status: ApplyStatus
    public var code: ErrorCode?
    public var doc: PlaylistDoc?
    public var changed: [EntityRef]

    public init(status: ApplyStatus, code: ErrorCode? = nil, doc: PlaylistDoc?, changed: [EntityRef]) {
        self.status = status
        self.code = code
        self.doc = doc
        self.changed = changed
    }
}

public struct ApplyScalarResult: Hashable, Sendable, Codable {
    public var status: ApplyStatus
    public var code: ErrorCode?
    public var scalar: Scalar?
    public var changed: [EntityRef]

    public init(status: ApplyStatus, code: ErrorCode? = nil, scalar: Scalar?, changed: [EntityRef]) {
        self.status = status
        self.code = code
        self.scalar = scalar
        self.changed = changed
    }
}

public struct SecondEvent: Hashable, Sendable, Codable {
    public var eventId: String
    public var recorded: Bool
    public var titleKey: String
    public var artistKey: String
    public var suppressed: Bool

    public init(eventId: String, recorded: Bool, titleKey: String, artistKey: String, suppressed: Bool = false) {
        self.eventId = eventId
        self.recorded = recorded
        self.titleKey = titleKey
        self.artistKey = artistKey
        self.suppressed = suppressed
    }
}
