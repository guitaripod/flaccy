import Foundation
import FlaccyCore
import GRDB

public struct ScrobbleRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {

    public static let databaseTableName = "scrobbles"

    public var id: Int64?
    public var trackTitle: String
    public var artist: String
    public var albumTitle: String
    public var timestamp: Date
    public var duration: Int
    public var submitted: Bool

    public init(
        id: Int64? = nil,
        trackTitle: String,
        artist: String,
        albumTitle: String,
        timestamp: Date,
        duration: Int,
        submitted: Bool
    ) {
        self.id = id
        self.trackTitle = trackTitle
        self.artist = artist
        self.albumTitle = albumTitle
        self.timestamp = timestamp
        self.duration = duration
        self.submitted = submitted
    }

    /// Writes the listen keys beside the fields they derive from, so every
    /// insert path stores them without its caller knowing they exist.
    public func encode(to container: inout PersistenceContainer) throws {
        let keys = ListenHistory.Keys(title: trackTitle, artist: artist, album: albumTitle)
        container["id"] = id
        container["trackTitle"] = trackTitle
        container["artist"] = artist
        container["albumTitle"] = albumTitle
        container["timestamp"] = timestamp
        container["duration"] = duration
        container["submitted"] = submitted
        container["titleKey"] = keys.title
        container["artistKey"] = keys.artist
        container["albumKey"] = keys.album
    }
}

public struct WeeklyChartCacheRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {

    public static let databaseTableName = "weeklyChartCache"

    public var id: Int64?
    public var chartType: String
    public var fromUts: Int
    public var toUts: Int
    public var name: String
    public var artist: String?
    public var playCount: Int
    public var rank: Int

    public init(
        id: Int64? = nil,
        chartType: String,
        fromUts: Int,
        toUts: Int,
        name: String,
        artist: String? = nil,
        playCount: Int,
        rank: Int
    ) {
        self.id = id
        self.chartType = chartType
        self.fromUts = fromUts
        self.toUts = toUts
        self.name = name
        self.artist = artist
        self.playCount = playCount
        self.rank = rank
    }
}

public struct SimilarArtistCacheRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {

    public static let databaseTableName = "similarArtistCache"

    public var id: Int64?
    public var artist: String
    public var similarName: String
    public var match: Double
    public var fetchedAt: Date

    public init(
        id: Int64? = nil,
        artist: String,
        similarName: String,
        match: Double,
        fetchedAt: Date
    ) {
        self.id = id
        self.artist = artist
        self.similarName = similarName
        self.match = match
        self.fetchedAt = fetchedAt
    }
}
