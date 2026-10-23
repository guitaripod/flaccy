import Foundation

public struct Track: Sendable, Hashable, Identifiable {

    public var id: URL { fileURL }

    public let fileURL: URL
    public let title: String
    public let artist: String
    public let albumTitle: String
    /// The release credit, settled by `DatabaseManager.resolveAlbumCredits()`;
    /// nil for a track read straight off disk whose file carried no
    /// `ALBUMARTIST` tag.
    public let albumArtist: String?
    public let trackNumber: Int
    public let duration: TimeInterval
    public let artwork: PlatformImage?
    public let dbID: Int64?
    public var codec: String?
    public var bitDepth: Int?
    public var sampleRate: Int?
    public var channels: Int?
    public var loved: Bool = false
    public var playCount: Int = 0

    public init(
        fileURL: URL,
        title: String,
        artist: String,
        albumTitle: String,
        albumArtist: String?,
        trackNumber: Int,
        duration: TimeInterval,
        artwork: PlatformImage?,
        dbID: Int64?,
        codec: String? = nil,
        bitDepth: Int? = nil,
        sampleRate: Int? = nil,
        channels: Int? = nil,
        loved: Bool = false,
        playCount: Int = 0
    ) {
        self.fileURL = fileURL
        self.title = title
        self.artist = artist
        self.albumTitle = albumTitle
        self.albumArtist = albumArtist
        self.trackNumber = trackNumber
        self.duration = duration
        self.artwork = artwork
        self.dbID = dbID
        self.codec = codec
        self.bitDepth = bitDepth
        self.sampleRate = sampleRate
        self.channels = channels
        self.loved = loved
        self.playCount = playCount
    }

    public static let losslessCodecs: Set<String> = ["FLAC", "ALAC", "WAV", "AIFF"]

    /// The release this track is filed under, falling back to its performing
    /// artist for a track no credit pass has reached.
    public var credit: String {
        guard let albumArtist, !albumArtist.isEmpty else { return artist }
        return albumArtist
    }

    public var isLossless: Bool {
        guard let codec else { return false }
        return Self.losslessCodecs.contains(codec.uppercased())
    }

    public var qualityBadge: String? {
        guard let codec else { return nil }
        var detail: String?
        if let bitDepth, let sampleRate {
            detail = "\(bitDepth)/\(Self.formatSampleRate(sampleRate))"
        } else if let sampleRate {
            detail = Self.formatSampleRate(sampleRate)
        }
        guard let detail else { return codec }
        return "\(codec) · \(detail)"
    }

    private static func formatSampleRate(_ hz: Int) -> String {
        let khz = Double(hz) / 1000
        if khz == khz.rounded() {
            return String(format: "%.0f", khz)
        }
        return String(format: "%.1f", khz)
    }

    public static func == (lhs: Track, rhs: Track) -> Bool {
        lhs.fileURL == rhs.fileURL
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(fileURL)
    }

    public func relabeled(albumTitle: String, artist: String) -> Track {
        guard albumTitle != self.albumTitle || artist != self.artist else { return self }
        return Track(
            fileURL: fileURL,
            title: title,
            artist: artist,
            albumTitle: albumTitle,
            albumArtist: albumArtist,
            trackNumber: trackNumber,
            duration: duration,
            artwork: artwork,
            dbID: dbID,
            codec: codec,
            bitDepth: bitDepth,
            sampleRate: sampleRate,
            channels: channels,
            loved: loved,
            playCount: playCount
        )
    }
}
