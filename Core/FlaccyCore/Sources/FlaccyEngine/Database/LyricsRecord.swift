import Foundation
import GRDB

public struct LyricsRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {

    public static let databaseTableName = "lyrics"

    public var id: Int64?
    public var trackTitle: String
    public var artist: String
    public var syncedLyrics: String?
    public var plainLyrics: String?
    public var instrumental: Bool
    public var fetchedAt: Date?
    public var lyricsfile: String?
    public var offsetMs: Int = 0
    public var revision: Int = 0

    public init(
        id: Int64? = nil,
        trackTitle: String,
        artist: String,
        syncedLyrics: String? = nil,
        plainLyrics: String? = nil,
        instrumental: Bool,
        fetchedAt: Date? = nil,
        lyricsfile: String? = nil,
        offsetMs: Int = 0,
        revision: Int = 0
    ) {
        self.id = id
        self.trackTitle = trackTitle
        self.artist = artist
        self.syncedLyrics = syncedLyrics
        self.plainLyrics = plainLyrics
        self.instrumental = instrumental
        self.fetchedAt = fetchedAt
        self.lyricsfile = lyricsfile
        self.offsetMs = offsetMs
        self.revision = revision
    }
}
