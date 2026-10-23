import Foundation
import GRDB

public enum WantlistState: String, Sendable {
    case wanted, dismissed, acquired
}

public enum WantlistKind: String, Sendable {
    case album, track, artist
}

public enum WantlistSource: String, Sendable {
    case history, loved, discovery, gap, upgrade, manual
}

public struct WantlistRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {

    public static let databaseTableName = "wantlist"

    public var id: Int64?
    public var normKey: String
    public var kind: String
    public var title: String
    public var artist: String
    public var imageURL: String?
    public var state: String
    public var source: String
    public var score: Double
    public var reason: String
    public var playCount: Int
    public var addedAt: Date
    public var resolvedAt: Date?
    public var acknowledged: Bool

    public init(
        id: Int64? = nil,
        normKey: String,
        kind: String,
        title: String,
        artist: String,
        imageURL: String? = nil,
        state: String,
        source: String,
        score: Double,
        reason: String,
        playCount: Int,
        addedAt: Date,
        resolvedAt: Date? = nil,
        acknowledged: Bool
    ) {
        self.id = id
        self.normKey = normKey
        self.kind = kind
        self.title = title
        self.artist = artist
        self.imageURL = imageURL
        self.state = state
        self.source = source
        self.score = score
        self.reason = reason
        self.playCount = playCount
        self.addedAt = addedAt
        self.resolvedAt = resolvedAt
        self.acknowledged = acknowledged
    }
}

public struct NewReleaseRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {

    public static let databaseTableName = "newReleaseCache"

    public var id: Int64?
    public var artist: String
    public var albumTitle: String
    public var releaseDate: Date
    public var imageURL: String?
    public var storeURL: String?
    public var fetchedAt: Date

    public init(
        id: Int64? = nil,
        artist: String,
        albumTitle: String,
        releaseDate: Date,
        imageURL: String? = nil,
        storeURL: String? = nil,
        fetchedAt: Date
    ) {
        self.id = id
        self.artist = artist
        self.albumTitle = albumTitle
        self.releaseDate = releaseDate
        self.imageURL = imageURL
        self.storeURL = storeURL
        self.fetchedAt = fetchedAt
    }
}
