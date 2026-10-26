public typealias Stamp = Int64

public enum Visibility: String, Hashable, Sendable, Codable {
    case `private`
    case household
}

public struct SongRef: Hashable, Sendable, Codable {
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
}

public struct PlaylistStamps: Hashable, Sendable, Codable {
    public var name: Stamp
    public var cover: Stamp
    public var visibility: Stamp
    public var alive: Stamp

    public init(name: Stamp, cover: Stamp, visibility: Stamp, alive: Stamp) {
        self.name = name
        self.cover = cover
        self.visibility = visibility
        self.alive = alive
    }
}

public struct Playlist: Hashable, Sendable, Codable {
    public var id: String
    public var owner: String
    public var name: String
    public var coverBlob: String?
    public var visibility: Visibility
    public var alive: Bool
    public var createdAt: Int64
    public var stamps: PlaylistStamps

    public init(
        id: String,
        owner: String,
        name: String,
        coverBlob: String? = nil,
        visibility: Visibility,
        alive: Bool,
        createdAt: Int64,
        stamps: PlaylistStamps
    ) {
        self.id = id
        self.owner = owner
        self.name = name
        self.coverBlob = coverBlob
        self.visibility = visibility
        self.alive = alive
        self.createdAt = createdAt
        self.stamps = stamps
    }
}

public struct EntryStamps: Hashable, Sendable, Codable {
    public var song: Stamp
    public var pos: Stamp
    public var alive: Stamp

    public init(song: Stamp, pos: Stamp, alive: Stamp) {
        self.song = song
        self.pos = pos
        self.alive = alive
    }

    private enum CodingKeys: String, CodingKey {
        case song = "ref"
        case pos
        case alive
    }
}

public struct Entry: Hashable, Sendable, Codable {
    public var id: String
    public var playlist: String
    public var song: SongRef
    public var pos: String
    public var alive: Bool
    public var stamps: EntryStamps

    public init(id: String, playlist: String, song: SongRef, pos: String, alive: Bool, stamps: EntryStamps) {
        self.id = id
        self.playlist = playlist
        self.song = song
        self.pos = pos
        self.alive = alive
        self.stamps = stamps
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case playlist
        case song = "ref"
        case pos
        case alive
        case stamps
    }
}

public struct PlaylistDoc: Hashable, Sendable, Codable {
    public var playlist: Playlist
    public var entries: [Entry]

    public init(playlist: Playlist, entries: [Entry]) {
        self.playlist = playlist
        self.entries = entries
    }
}

public struct Love: Hashable, Sendable, Codable {
    public var songKey: String
    public var song: SongRef
    public var loved: Bool
    public var stamp: Stamp

    public init(songKey: String, song: SongRef, loved: Bool, stamp: Stamp) {
        self.songKey = songKey
        self.song = song
        self.loved = loved
        self.stamp = stamp
    }

    private enum CodingKeys: String, CodingKey {
        case songKey
        case song = "ref"
        case loved
        case stamp
    }
}

public struct Rating: Hashable, Sendable, Codable {
    public var songKey: String
    public var song: SongRef
    public var rating: UInt8?
    public var stamp: Stamp

    public init(songKey: String, song: SongRef, rating: UInt8?, stamp: Stamp) {
        self.songKey = songKey
        self.song = song
        self.rating = rating
        self.stamp = stamp
    }

    private enum CodingKeys: String, CodingKey {
        case songKey
        case song = "ref"
        case rating
        case stamp
    }
}

public struct Scalar: Hashable, Sendable, Codable {
    public var key: String
    public var value: JSONValue
    public var deleted: Bool
    public var stamp: Stamp

    public init(key: String, value: JSONValue, deleted: Bool, stamp: Stamp) {
        self.key = key
        self.value = value
        self.deleted = deleted
        self.stamp = stamp
    }
}

public struct SessionDoc: Hashable, Sendable, Codable {
    public var device: String
    public var session: JSONValue
    public var stamp: Stamp

    public init(device: String, session: JSONValue, stamp: Stamp) {
        self.device = device
        self.session = session
        self.stamp = stamp
    }
}
