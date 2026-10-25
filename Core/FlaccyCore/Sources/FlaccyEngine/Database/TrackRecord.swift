import Foundation
import GRDB

public struct TrackRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {

    public static let databaseTableName = "tracks"

    public var id: Int64?
    public var fileURL: String
    public var title: String
    public var artist: String
    public var albumTitle: String
    public var albumArtist: String?
    public var trackNumber: Int
    public var duration: Double
    public var artworkData: Data?
    public var lastFMArtworkURL: String?
    public var musicBrainzID: String?
    public var albumMusicBrainzID: String?
    public var dateAdded: Date
    public var lastPlayed: Date?
    public var playCount: Int
    public var aiAnalyzed: Bool
    public var analysisAttemptedAt: Date?
    public var codec: String?
    public var bitDepth: Int?
    public var sampleRate: Int?
    public var channels: Int?
    public var loved: Bool = false
    public var lovedPendingOp: String?
    public var fileSize: Int64?
    public var fileModifiedMs: Int64?
    public var audioFingerprint: String?
    public var revision: Int = 1
    public var revisedAt: Date?

    public init(
        id: Int64? = nil,
        fileURL: String,
        title: String,
        artist: String,
        albumTitle: String,
        albumArtist: String? = nil,
        trackNumber: Int,
        duration: Double,
        artworkData: Data? = nil,
        lastFMArtworkURL: String? = nil,
        musicBrainzID: String? = nil,
        albumMusicBrainzID: String? = nil,
        dateAdded: Date,
        lastPlayed: Date? = nil,
        playCount: Int,
        aiAnalyzed: Bool,
        analysisAttemptedAt: Date? = nil,
        codec: String? = nil,
        bitDepth: Int? = nil,
        sampleRate: Int? = nil,
        channels: Int? = nil,
        loved: Bool = false,
        lovedPendingOp: String? = nil,
        fileSize: Int64? = nil,
        fileModifiedMs: Int64? = nil,
        audioFingerprint: String? = nil,
        revision: Int = 1,
        revisedAt: Date? = nil
    ) {
        self.id = id
        self.fileURL = fileURL
        self.title = title
        self.artist = artist
        self.albumTitle = albumTitle
        self.albumArtist = albumArtist
        self.trackNumber = trackNumber
        self.duration = duration
        self.artworkData = artworkData
        self.lastFMArtworkURL = lastFMArtworkURL
        self.musicBrainzID = musicBrainzID
        self.albumMusicBrainzID = albumMusicBrainzID
        self.dateAdded = dateAdded
        self.lastPlayed = lastPlayed
        self.playCount = playCount
        self.aiAnalyzed = aiAnalyzed
        self.analysisAttemptedAt = analysisAttemptedAt
        self.codec = codec
        self.bitDepth = bitDepth
        self.sampleRate = sampleRate
        self.channels = channels
        self.loved = loved
        self.lovedPendingOp = lovedPendingOp
        self.fileSize = fileSize
        self.fileModifiedMs = fileModifiedMs
        self.audioFingerprint = audioFingerprint
        self.revision = revision
        self.revisedAt = revisedAt
    }
}

public struct LightTrackRecord: Codable, FetchableRecord, Identifiable, Sendable {

    public var id: Int64?
    public var fileURL: String
    public var title: String
    public var artist: String
    public var albumTitle: String
    public var albumArtist: String?
    public var trackNumber: Int
    public var duration: Double
    public var dateAdded: Date
    public var lastPlayed: Date?
    public var playCount: Int
    public var loved: Bool = false
    public var codec: String?
    public var bitDepth: Int?
    public var sampleRate: Int?
    public var channels: Int?
    public var fileModifiedMs: Int64?
    public var revision: Int = 1
    public var revisedAt: Date?

    public init(
        id: Int64? = nil,
        fileURL: String,
        title: String,
        artist: String,
        albumTitle: String,
        albumArtist: String? = nil,
        trackNumber: Int,
        duration: Double,
        dateAdded: Date,
        lastPlayed: Date? = nil,
        playCount: Int,
        loved: Bool = false,
        codec: String? = nil,
        bitDepth: Int? = nil,
        sampleRate: Int? = nil,
        channels: Int? = nil,
        fileModifiedMs: Int64? = nil,
        revision: Int = 1,
        revisedAt: Date? = nil
    ) {
        self.id = id
        self.fileURL = fileURL
        self.title = title
        self.artist = artist
        self.albumTitle = albumTitle
        self.albumArtist = albumArtist
        self.trackNumber = trackNumber
        self.duration = duration
        self.dateAdded = dateAdded
        self.lastPlayed = lastPlayed
        self.playCount = playCount
        self.loved = loved
        self.codec = codec
        self.bitDepth = bitDepth
        self.sampleRate = sampleRate
        self.channels = channels
        self.fileModifiedMs = fileModifiedMs
        self.revision = revision
        self.revisedAt = revisedAt
    }
}

/// The release credit a row belongs to, falling back to its own performing
/// artist for a row `DatabaseManager.resolveAlbumCredits()` has not settled yet.
extension TrackRecord {
    public var credit: String {
        guard let albumArtist, !albumArtist.isEmpty else { return artist }
        return albumArtist
    }
}

extension LightTrackRecord {
    public var credit: String {
        guard let albumArtist, !albumArtist.isEmpty else { return artist }
        return albumArtist
    }
}
