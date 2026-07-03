import AVFoundation
import UIKit

enum MetadataService {

    nonisolated static func extractMetadata(from url: URL) async -> Track {
        let asset = AVURLAsset(url: url)
        let duration: TimeInterval
        let metadata: [AVMetadataItem]

        do {
            let loaded = try await asset.load(.duration, .metadata)
            duration = CMTimeGetSeconds(loaded.0)
            metadata = loaded.1
        } catch {
            await AppLogger.error("Metadata load failed for \(url.lastPathComponent): \(error.localizedDescription)", category: .content)
            duration = 0
            metadata = []
        }

        async let titleTask = stringValue(for: .commonIdentifierTitle, in: metadata)
        async let artistTask = stringValue(for: .commonIdentifierArtist, in: metadata)
        async let albumTask = stringValue(for: .commonIdentifierAlbumName, in: metadata)
        async let trackNumberTask = trackNumberValue(from: metadata)
        async let artworkTask = artworkImage(from: metadata)

        let embeddedTitle = await titleTask
        let embeddedArtist = await artistTask
        let embeddedAlbum = await albumTask
        let trackNumber = await trackNumberTask
        let artwork = await artworkTask

        let pathInfo = parsePathInfo(from: url)
        let fileInfo = parseFilename(url.deletingPathExtension().lastPathComponent)

        let title = embeddedTitle ?? fileInfo.title
        let artist = embeddedArtist ?? pathInfo.artist ?? "Unknown Artist"
        let albumTitle = embeddedAlbum ?? pathInfo.album ?? "Unknown Album"
        let finalTrackNumber = trackNumber > 0 ? trackNumber : fileInfo.trackNumber

        let format = readFormat(from: url)

        return Track(
            fileURL: url,
            title: title,
            artist: artist,
            albumTitle: albumTitle,
            trackNumber: finalTrackNumber,
            duration: duration,
            artwork: artwork,
            dbID: nil,
            codec: format.codec,
            bitDepth: format.bitDepth,
            sampleRate: format.sampleRate,
            channels: format.channels
        )
    }

    nonisolated struct AudioFormatInfo: Sendable {
        let codec: String?
        let bitDepth: Int?
        let sampleRate: Int?
        let channels: Int?
    }

    /// Extracts codec/bit-depth/sample-rate/channels. FLAC bit depth comes from
    /// the STREAMINFO block (compressed formats report 0 via CoreAudio); other
    /// PCM/lossless formats read from the source `AVAudioFile` file format.
    /// Returns nil components on any parse failure and never crashes.
    nonisolated static func readFormat(from url: URL) -> AudioFormatInfo {
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

        return AudioFormatInfo(codec: codec, bitDepth: bitDepth, sampleRate: sampleRate, channels: channels)
    }

    nonisolated private static func codecName(forExtension ext: String) -> String? {
        switch ext {
        case "flac": "FLAC"
        case "alac": "ALAC"
        case "mp3": "MP3"
        case "wav": "WAV"
        case "aiff", "aif": "AIFF"
        case "aac": "AAC"
        default: nil
        }
    }

    nonisolated private static func parseFLACStreamInfo(url: URL) -> (sampleRate: Int, channels: Int, bitsPerSample: Int)? {
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

    private nonisolated struct PathInfo {
        let artist: String?
        let album: String?
    }

    private nonisolated struct FileInfo {
        let title: String
        let trackNumber: Int
    }

    nonisolated private static func parsePathInfo(from url: URL) -> PathInfo {
        let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].standardizedFileURL
        let docsPath = docsDir.path
        let filePath = url.standardizedFileURL.deletingLastPathComponent().path

        guard filePath.count > docsPath.count else {
            return PathInfo(artist: nil, album: nil)
        }

        var relativeDirPath = String(filePath.dropFirst(docsPath.count))
        if relativeDirPath.hasPrefix("/") {
            relativeDirPath = String(relativeDirPath.dropFirst())
        }
        let components = relativeDirPath.split(separator: "/").map(String.init)

        switch components.count {
        case 1:
            return PathInfo(artist: nil, album: components[0])
        case 2...:
            return PathInfo(artist: components[0], album: components[1])
        default:
            return PathInfo(artist: nil, album: nil)
        }
    }

    nonisolated private static func parseFilename(_ filename: String) -> FileInfo {
        var name = filename
        var trackNumber = 0

        let patterns: [(regex: String, titleGroup: Int, trackGroup: Int)] = [
            (#"^(\d{1,3})\s*[-._)\]]\s*(.+)$"#, 2, 1),
            (#"^(\d{1,3})\s+(.+)$"#, 2, 1),
        ]

        let original = name
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern.regex),
                  let match = regex.firstMatch(in: original, range: NSRange(original.startIndex..., in: original))
            else { continue }

            if let trackRange = Range(match.range(at: pattern.trackGroup), in: original) {
                trackNumber = Int(original[trackRange]) ?? 0
            }
            if let titleRange = Range(match.range(at: pattern.titleGroup), in: original) {
                let parsedTitle = String(original[titleRange]).trimmingCharacters(in: .whitespaces)
                if !parsedTitle.isEmpty { name = parsedTitle }
            }
            break
        }

        name = name
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)

        return FileInfo(title: name, trackNumber: trackNumber)
    }

    nonisolated private static func stringValue(
        for identifier: AVMetadataIdentifier,
        in metadata: [AVMetadataItem]
    ) async -> String? {
        let items = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: identifier)
        guard let item = items.first else { return nil }
        return try? await item.load(.stringValue)
    }

    nonisolated private static func trackNumberValue(from metadata: [AVMetadataItem]) async -> Int {
        for item in metadata {
            if let key = item.key as? String, key.uppercased() == "TRACKNUMBER",
               let value = try? await item.load(.stringValue),
               let number = Int(value.components(separatedBy: "/").first ?? value) {
                return number
            }
        }

        let identifiers: [AVMetadataIdentifier] = [
            .id3MetadataTrackNumber,
            .iTunesMetadataTrackNumber,
        ]
        for identifier in identifiers {
            let items = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: identifier)
            if let item = items.first, let value = try? await item.load(.numberValue) {
                return value.intValue
            }
        }
        return 0
    }

    nonisolated private static func artworkImage(from metadata: [AVMetadataItem]) async -> UIImage? {
        let items = AVMetadataItem.metadataItems(
            from: metadata, filteredByIdentifier: .commonIdentifierArtwork
        )
        guard let item = items.first, let data = try? await item.load(.dataValue) else { return nil }
        return UIImage(data: data)
    }
}
