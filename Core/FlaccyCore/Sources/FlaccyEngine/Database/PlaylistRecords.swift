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

public struct PlaylistTrackRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {

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
