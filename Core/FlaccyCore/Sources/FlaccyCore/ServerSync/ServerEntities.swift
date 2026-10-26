import Foundation

/// A song as one client names it; `songKey` is the identity (PROTOCOL.md section 1.2).
public struct ServerSongRef: Hashable, Sendable, Codable {
    public var songKey: String
    public var title: String
    public var artist: String
    public var album: String
    public var durationMs: Int64
    public var fp: String?
    public var mbid: String?
    public var albumKey: String?
    public var relPath: String?

    public init(
        songKey: String,
        title: String,
        artist: String,
        album: String = "",
        durationMs: Int64 = 0,
        fp: String? = nil,
        mbid: String? = nil,
        albumKey: String? = nil,
        relPath: String? = nil
    ) {
        self.songKey = songKey
        self.title = title
        self.artist = artist
        self.album = album
        self.durationMs = durationMs
        self.fp = fp
        self.mbid = mbid
        self.albumKey = albumKey
        self.relPath = relPath
    }

    private enum CodingKeys: String, CodingKey {
        case songKey, title, artist, album, durationMs, fp, mbid, albumKey, relPath
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        songKey = try container.decode(String.self, forKey: .songKey)
        title = try container.decode(String.self, forKey: .title)
        artist = try container.decode(String.self, forKey: .artist)
        album = try container.decodeIfPresent(String.self, forKey: .album) ?? ""
        durationMs = try container.decodeIfPresent(Int64.self, forKey: .durationMs) ?? 0
        fp = try container.decodeIfPresent(String.self, forKey: .fp)
        mbid = try container.decodeIfPresent(String.self, forKey: .mbid)
        albumKey = try container.decodeIfPresent(String.self, forKey: .albumKey)
        relPath = try container.decodeIfPresent(String.self, forKey: .relPath)
    }
}

public enum ServerVisibility: String, Hashable, Sendable, Codable {
    case `private`
    case household
}

public enum ServerListenSource: String, Hashable, Sendable, Codable {
    case flaccy
    case lastfm
    case opensubsonic
    case migrated
}

public struct ServerPlaylistStamps: Hashable, Sendable, Codable {
    public var name: Int64
    public var cover: Int64
    public var visibility: Int64
    public var alive: Int64
}

public struct ServerPlaylistValue: Hashable, Sendable, Codable {
    public var id: String
    public var owner: String
    public var name: String
    public var coverBlob: String?
    public var visibility: ServerVisibility
    public var alive: Bool
    public var createdAt: Int64
    public var stamps: ServerPlaylistStamps
}

public struct ServerEntryStamps: Hashable, Sendable, Codable {
    public var ref: Int64
    public var pos: Int64
    public var alive: Int64
}

public struct ServerEntryValue: Hashable, Sendable, Codable {
    public var id: String
    public var playlist: String
    public var ref: ServerSongRef
    public var pos: String
    public var alive: Bool
    public var stamps: ServerEntryStamps
}

public struct ServerLoveValue: Hashable, Sendable, Codable {
    public var songKey: String
    public var ref: ServerSongRef
    public var loved: Bool
    public var stamp: Int64

    public init(songKey: String, ref: ServerSongRef, loved: Bool, stamp: Int64) {
        self.songKey = songKey
        self.ref = ref
        self.loved = loved
        self.stamp = stamp
    }
}

public struct ServerScalarValue: Hashable, Sendable, Codable {
    public var key: String
    public var value: ServerJSON
    public var deleted: Bool
    public var stamp: Int64

    public init(key: String, value: ServerJSON, deleted: Bool, stamp: Int64) {
        self.key = key
        self.value = value
        self.deleted = deleted
        self.stamp = stamp
    }
}

public struct ServerSessionValue: Hashable, Sendable, Codable {
    public var device: String
    public var session: ServerJSON
    public var stamp: Int64
}

public struct ServerListenValue: Hashable, Sendable, Codable {
    public var eventId: String
    public var ts: Int64
    public var ref: ServerSongRef
    public var playedS: Int64
    public var source: ServerListenSource
    public var recorded: Bool
    public var device: String?
    public var suppressed: Bool
}

/// One listen of a `listen.record` mutation.
public struct ServerListenInput: Hashable, Sendable, Codable {
    public var eventId: String
    public var ts: Int64
    public var ref: ServerSongRef
    public var playedS: Int64
    public var recorded: Bool

    public init(eventId: String, ts: Int64, ref: ServerSongRef, playedS: Int64, recorded: Bool) {
        self.eventId = eventId
        self.ts = ts
        self.ref = ref
        self.playedS = playedS
        self.recorded = recorded
    }
}

/// The kinds of synced entity. A kind this build does not know decodes as `unknown` and is skipped.
public enum ServerEntityKind: Hashable, Sendable, Codable {
    case playlist
    case playlistEntry
    case love
    case rating
    case scalar
    case session
    case listen
    case unknown(String)

    public init(from decoder: any Decoder) throws {
        let word = try decoder.singleValueContainer().decode(String.self)
        self = Self.known[word] ?? .unknown(word)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireName)
    }

    public var wireName: String {
        switch self {
        case .playlist: "playlist"
        case .playlistEntry: "playlist_entry"
        case .love: "love"
        case .rating: "rating"
        case .scalar: "scalar"
        case .session: "session"
        case .listen: "listen"
        case .unknown(let word): word
        }
    }

    private static let known: [String: ServerEntityKind] = [
        "playlist": .playlist, "playlist_entry": .playlistEntry, "love": .love, "rating": .rating,
        "scalar": .scalar, "session": .session, "listen": .listen,
    ]
}

/// A pulled entity decoded by its kind.
public enum ServerEntityValue: Hashable, Sendable {
    case playlist(ServerPlaylistValue)
    case entry(ServerEntryValue)
    case love(ServerLoveValue)
    case scalar(ServerScalarValue)
    case session(ServerSessionValue)
    case listen(ServerListenValue)
    case rating(ServerJSON)

    /// Decodes `value` as the entity `kind` names, or nil for a kind this build does not know or a value that does not fit it.
    public init?(kind: ServerEntityKind, value: ServerJSON) {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        let decoder = JSONDecoder()
        switch kind {
        case .playlist:
            guard let decoded = try? decoder.decode(ServerPlaylistValue.self, from: data) else { return nil }
            self = .playlist(decoded)
        case .playlistEntry:
            guard let decoded = try? decoder.decode(ServerEntryValue.self, from: data) else { return nil }
            self = .entry(decoded)
        case .love:
            guard let decoded = try? decoder.decode(ServerLoveValue.self, from: data) else { return nil }
            self = .love(decoded)
        case .scalar:
            guard let decoded = try? decoder.decode(ServerScalarValue.self, from: data) else { return nil }
            self = .scalar(decoded)
        case .session:
            guard let decoded = try? decoder.decode(ServerSessionValue.self, from: data) else { return nil }
            self = .session(decoded)
        case .listen:
            guard let decoded = try? decoder.decode(ServerListenValue.self, from: data) else { return nil }
            self = .listen(decoded)
        case .rating:
            self = .rating(value)
        case .unknown:
            return nil
        }
    }
}
