import Foundation
import GRDB

public struct ArtistRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {

    public static let databaseTableName = "artists"

    public var id: Int64?
    public var name: String
    public var bio: String?
    public var imageURL: String?
    public var musicBrainzID: String?
    public var lastFetched: Date?

    public init(
        id: Int64? = nil,
        name: String,
        bio: String? = nil,
        imageURL: String? = nil,
        musicBrainzID: String? = nil,
        lastFetched: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.bio = bio
        self.imageURL = imageURL
        self.musicBrainzID = musicBrainzID
        self.lastFetched = lastFetched
    }
}

public struct AlbumInfoRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {

    public static let databaseTableName = "albumInfo"

    public var id: Int64?
    public var title: String
    public var artist: String
    public var coverArtURL: String?
    public var coverArtData: Data?
    public var musicBrainzID: String?
    public var year: String?
    public var genre: String?
    public var lastFetched: Date?

    public init(
        id: Int64? = nil,
        title: String,
        artist: String,
        coverArtURL: String? = nil,
        coverArtData: Data? = nil,
        musicBrainzID: String? = nil,
        year: String? = nil,
        genre: String? = nil,
        lastFetched: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.coverArtURL = coverArtURL
        self.coverArtData = coverArtData
        self.musicBrainzID = musicBrainzID
        self.year = year
        self.genre = genre
        self.lastFetched = lastFetched
    }
}
