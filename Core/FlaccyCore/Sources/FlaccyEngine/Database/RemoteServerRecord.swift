import Foundation
import GRDB

/// How a remote server is asked to prove who the person is.
public enum RemoteAuthKind: String, Sendable, Codable {
    case apiKey
    case password
}

/// One music server the person added: where it is, who they are on it, and what it told Flaccy
/// about itself. Its secret (password or API key) is never in this row, only in the Keychain.
public struct RemoteServerRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable, Equatable {

    public static let databaseTableName = "remoteServers"

    public var id: String
    public var name: String
    public var baseURL: String
    public var username: String
    public var authKind: String
    public var serverType: String?
    public var serverVersion: String?
    /// A JSON array of the OpenSubsonic extension names the server listed.
    public var extensions: String
    public var addedAt: Date
    public var lastSyncedAt: Date?

    public init(
        id: String,
        name: String,
        baseURL: String,
        username: String,
        authKind: RemoteAuthKind,
        serverType: String? = nil,
        serverVersion: String? = nil,
        extensionNames: [String] = [],
        addedAt: Date,
        lastSyncedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.username = username
        self.authKind = authKind.rawValue
        self.serverType = serverType
        self.serverVersion = serverVersion
        self.extensions = Self.encode(extensionNames)
        self.addedAt = addedAt
        self.lastSyncedAt = lastSyncedAt
    }

    public var auth: RemoteAuthKind {
        RemoteAuthKind(rawValue: authKind) ?? .password
    }

    public var extensionNames: [String] {
        get { (try? JSONDecoder().decode([String].self, from: Data(extensions.utf8))) ?? [] }
        set { extensions = Self.encode(newValue) }
    }

    private static func encode(_ names: [String]) -> String {
        guard let data = try? JSONEncoder().encode(names), let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }
}

/// What a remote song's row says about its file, enough to ask the server for it and to play it.
public struct RemoteSongSource: Sendable, Equatable {
    public let path: String
    public let suffix: String?
    public let size: Int64?
    public let duration: Double
    public let pinned: Bool

    public init(path: String, suffix: String?, size: Int64?, duration: Double, pinned: Bool) {
        self.path = path
        self.suffix = suffix
        self.size = size
        self.duration = duration
        self.pinned = pinned
    }
}

/// A song as a server's catalog lists it, shaped for the row it becomes or refreshes.
public struct RemoteSongFacts: Sendable, Equatable {
    public var title: String
    public var artist: String
    public var albumTitle: String
    public var albumArtist: String?
    public var trackNumber: Int
    public var duration: Double
    public var suffix: String?
    public var size: Int64?
    public var coverArt: String?
    public var albumId: String?
    public var codec: String?
    public var bitDepth: Int?
    public var sampleRate: Int?
    public var channels: Int?
    public var fingerprint: String?

    public init(
        title: String,
        artist: String,
        albumTitle: String,
        albumArtist: String?,
        trackNumber: Int,
        duration: Double,
        suffix: String?,
        size: Int64?,
        coverArt: String?,
        albumId: String?,
        codec: String?,
        bitDepth: Int?,
        sampleRate: Int?,
        channels: Int?,
        fingerprint: String?
    ) {
        self.title = title
        self.artist = artist
        self.albumTitle = albumTitle
        self.albumArtist = albumArtist
        self.trackNumber = trackNumber
        self.duration = duration
        self.suffix = suffix
        self.size = size
        self.coverArt = coverArt
        self.albumId = albumId
        self.codec = codec
        self.bitDepth = bitDepth
        self.sampleRate = sampleRate
        self.channels = channels
        self.fingerprint = fingerprint
    }
}

/// What the server remembers of the person's own listening to one song.
public struct RemoteSongPlayState: Sendable, Equatable {
    public let songID: String
    public let starred: Bool
    public let playCount: Int?
    public let played: Date?

    public init(songID: String, starred: Bool, playCount: Int?, played: Date?) {
        self.songID = songID
        self.starred = starred
        self.playCount = playCount
        self.played = played
    }
}

/// One server's catalog change, applied to its rows in a single transaction.
public struct RemoteCatalogChange: Sendable {
    public var serverID: String
    public var inserts: [(songID: String, facts: RemoteSongFacts)]
    public var updates: [(songID: String, facts: RemoteSongFacts)]
    public var newVersions: [(songID: String, facts: RemoteSongFacts)]
    public var removedSongIDs: [String]
    public var playStates: [RemoteSongPlayState]
    public var now: Date

    public init(
        serverID: String,
        inserts: [(songID: String, facts: RemoteSongFacts)],
        updates: [(songID: String, facts: RemoteSongFacts)],
        newVersions: [(songID: String, facts: RemoteSongFacts)],
        removedSongIDs: [String],
        playStates: [RemoteSongPlayState] = [],
        now: Date
    ) {
        self.serverID = serverID
        self.inserts = inserts
        self.updates = updates
        self.newVersions = newVersions
        self.removedSongIDs = removedSongIDs
        self.playStates = playStates
        self.now = now
    }
}
