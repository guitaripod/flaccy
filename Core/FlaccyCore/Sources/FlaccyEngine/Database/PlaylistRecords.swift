import Foundation
import GRDB

public struct PlaylistRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {

    public static let databaseTableName = "playlists"

    public var id: Int64?
    public var name: String
    public var createdAt: Date

    public init(
        id: Int64? = nil,
        name: String,
        createdAt: Date
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}

public struct PlaylistTrackRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable, Equatable {

    public static let databaseTableName = "playlistTracks"

    public var id: Int64?
    public var playlistId: Int64
    public var trackFileURL: String
    public var position: Int

    public init(
        id: Int64? = nil,
        playlistId: Int64,
        trackFileURL: String,
        position: Int
    ) {
        self.id = id
        self.playlistId = playlistId
        self.trackFileURL = trackFileURL
        self.position = position
    }
}

/// How many songs a playlist holds and how long the ones the library still
/// has play.
public struct PlaylistSummary: Sendable, Equatable {
    public let songCount: Int
    public let seconds: Double

    public init(songCount: Int, seconds: Double) {
        self.songCount = songCount
        self.seconds = seconds
    }
}

/// One song in a playlist: its row, and the library's row for the song, or
/// nil when the library no longer has it.
public struct PlaylistEntry: Sendable, Equatable {
    public let record: PlaylistTrackRecord
    public let track: TrackRecord?

    public init(record: PlaylistTrackRecord, track: TrackRecord?) {
        self.record = record
        self.track = track
    }
}
