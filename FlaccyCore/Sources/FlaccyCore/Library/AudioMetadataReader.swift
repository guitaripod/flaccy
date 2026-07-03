import AVFoundation
import Foundation

/// Reads embedded metadata + duration from an audio file using AVFoundation.
/// Cross-platform (iOS + watchOS); artwork is returned as raw `Data`.
public enum AudioMetadataReader {

    public struct Result: Sendable {
        public let title: String?
        public let artist: String?
        public let albumTitle: String?
        public let trackNumber: Int
        public let duration: TimeInterval
        public let artworkData: Data?
        public let codec: String?
        public let bitDepth: Int?
        public let sampleRate: Int?
        public let channels: Int?

        public init(
            title: String?,
            artist: String?,
            albumTitle: String?,
            trackNumber: Int,
            duration: TimeInterval,
            artworkData: Data?,
            codec: String? = nil,
            bitDepth: Int? = nil,
            sampleRate: Int? = nil,
            channels: Int? = nil
        ) {
            self.title = title
            self.artist = artist
            self.albumTitle = albumTitle
            self.trackNumber = trackNumber
            self.duration = duration
            self.artworkData = artworkData
            self.codec = codec
            self.bitDepth = bitDepth
            self.sampleRate = sampleRate
            self.channels = channels
        }
    }

    public struct FormatInfo: Sendable {
        public let codec: String?
        public let bitDepth: Int?
        public let sampleRate: Int?
        public let channels: Int?
    }

    public static func read(from url: URL) async -> Result {
        let asset = AVURLAsset(url: url)
        let duration: TimeInterval
        let metadata: [AVMetadataItem]

        do {
            let loaded = try await asset.load(.duration, .metadata)
            duration = CMTimeGetSeconds(loaded.0)
            metadata = loaded.1
        } catch {
            AppLogger.error("Metadata load failed for \(url.lastPathComponent): \(error.localizedDescription)", category: .content)
            return Result(title: nil, artist: nil, albumTitle: nil, trackNumber: 0, duration: 0, artworkData: nil)
        }

        async let titleTask = stringValue(for: .commonIdentifierTitle, in: metadata)
        async let artistTask = stringValue(for: .commonIdentifierArtist, in: metadata)
        async let albumTask = stringValue(for: .commonIdentifierAlbumName, in: metadata)
        async let trackTask = trackNumberValue(from: metadata)
        async let artworkTask = artworkData(from: metadata)

        let format = readFormat(from: url)

        return Result(
            title: await titleTask,
            artist: await artistTask,
            albumTitle: await albumTask,
            trackNumber: await trackTask,
            duration: duration.isNaN ? 0 : duration,
            artworkData: await artworkTask,
            codec: format.codec,
            bitDepth: format.bitDepth,
            sampleRate: format.sampleRate,
            channels: format.channels
        )
    }

    /// Extracts codec/bit-depth/sample-rate/channels. FLAC bit depth is parsed
    /// from the STREAMINFO block; other formats read from the source file format.
    /// Returns nil components on any parse failure and never crashes.
    public static func readFormat(from url: URL) -> FormatInfo {
        let ext = url.pathExtension.lowercased()
        var codec = codecName(forExtension: ext)
        var sampleRate: Int?
        var channels: Int?
        var bitDepth: Int?

        if ext == "flac" {
            codec = "FLAC"
            if let stream = parseFLACStreamInfo(url: url) {
                sampleRate = stream.sampleRate
                channels = stream.channels
                bitDepth = stream.bitsPerSample
            }
        }

        if let file = try? AVAudioFile(forReading: url) {
            let asbd = file.fileFormat.streamDescription.pointee
            if sampleRate == nil, asbd.mSampleRate > 0 { sampleRate = Int(asbd.mSampleRate) }
            if channels == nil, asbd.mChannelsPerFrame > 0 { channels = Int(asbd.mChannelsPerFrame) }
            if bitDepth == nil, asbd.mBitsPerChannel > 0 { bitDepth = Int(asbd.mBitsPerChannel) }
            if codec == nil {
                switch asbd.mFormatID {
                case kAudioFormatAppleLossless: codec = "ALAC"
                case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_LD: codec = "AAC"
                case kAudioFormatMPEGLayer3: codec = "MP3"
                case kAudioFormatLinearPCM: codec = "WAV"
                default: break
                }
            }
        }

        return FormatInfo(codec: codec, bitDepth: bitDepth, sampleRate: sampleRate, channels: channels)
    }

    private static func codecName(forExtension ext: String) -> String? {
        switch ext {
        case "flac": return "FLAC"
        case "alac": return "ALAC"
        case "mp3": return "MP3"
        case "wav": return "WAV"
        case "aiff", "aif": return "AIFF"
        case "aac": return "AAC"
        default: return nil
        }
    }

    private static func parseFLACStreamInfo(url: URL) -> (sampleRate: Int, channels: Int, bitsPerSample: Int)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 42), header.count >= 42 else { return nil }
        let bytes = [UInt8](header)
        guard bytes[0] == 0x66, bytes[1] == 0x4C, bytes[2] == 0x61, bytes[3] == 0x43 else { return nil }
        guard bytes[4] & 0x7F == 0 else { return nil }

        let base = 8
        let b10 = Int(bytes[base + 10])
        let b11 = Int(bytes[base + 11])
        let b12 = Int(bytes[base + 12])
        let b13 = Int(bytes[base + 13])

        let sampleRate = (b10 << 12) | (b11 << 4) | (b12 >> 4)
        let channels = ((b12 >> 1) & 0x07) + 1
        let bitsPerSample = (((b12 & 0x01) << 4) | (b13 >> 4)) + 1
        guard sampleRate > 0 else { return nil }
        return (sampleRate, channels, bitsPerSample)
    }

    private static func stringValue(
        for identifier: AVMetadataIdentifier,
        in metadata: [AVMetadataItem]
    ) async -> String? {
        let items = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: identifier)
        guard let item = items.first else { return nil }
        let value = try? await item.load(.stringValue)
        return value?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func trackNumberValue(from metadata: [AVMetadataItem]) async -> Int {
        for item in metadata {
            if let key = item.key as? String, key.uppercased() == "TRACKNUMBER",
               let value = try? await item.load(.stringValue),
               let number = Int(value.components(separatedBy: "/").first ?? value) {
                return number
            }
        }

        let identifiers: [AVMetadataIdentifier] = [.id3MetadataTrackNumber, .iTunesMetadataTrackNumber]
        for identifier in identifiers {
            let items = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: identifier)
            if let item = items.first, let value = try? await item.load(.numberValue) {
                return value.intValue
            }
        }
        return 0
    }

    private static func artworkData(from metadata: [AVMetadataItem]) async -> Data? {
        let items = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierArtwork)
        guard let item = items.first else { return nil }
        return try? await item.load(.dataValue)
    }
}
