import Foundation

nonisolated struct Track: Sendable, Hashable, Identifiable {

    var id: URL { fileURL }

    let fileURL: URL
    let title: String
    let artist: String
    let albumTitle: String
    let trackNumber: Int
    let duration: TimeInterval
    let artwork: PlatformImage?
    let dbID: Int64?
    var codec: String?
    var bitDepth: Int?
    var sampleRate: Int?
    var channels: Int?
    var loved: Bool = false

    var isLossless: Bool {
        guard let codec else { return false }
        return ["FLAC", "ALAC", "WAV", "AIFF"].contains(codec.uppercased())
    }

    var qualityBadge: String? {
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

    static func == (lhs: Track, rhs: Track) -> Bool {
        lhs.fileURL == rhs.fileURL
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(fileURL)
    }

    static func from(record: TrackRecord, artwork: PlatformImage?) -> Track {
        let absoluteURL = LibraryPaths.root.appendingPathComponent(record.fileURL)
        return Track(
            fileURL: absoluteURL,
            title: record.title,
            artist: record.artist,
            albumTitle: record.albumTitle,
            trackNumber: record.trackNumber,
            duration: record.duration,
            artwork: artwork,
            dbID: record.id,
            codec: record.codec,
            bitDepth: record.bitDepth,
            sampleRate: record.sampleRate,
            channels: record.channels,
            loved: record.loved
        )
    }

    static func from(light record: LightTrackRecord, artwork: PlatformImage?) -> Track {
        let absoluteURL = LibraryPaths.root.appendingPathComponent(record.fileURL)
        return Track(
            fileURL: absoluteURL,
            title: record.title,
            artist: record.artist,
            albumTitle: record.albumTitle,
            trackNumber: record.trackNumber,
            duration: record.duration,
            artwork: artwork,
            dbID: record.id,
            codec: nil,
            bitDepth: nil,
            sampleRate: nil,
            channels: nil,
            loved: record.loved
        )
    }
}
