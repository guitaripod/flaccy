import FlaccyCore
import FlaccyEngine
import Foundation

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

enum MetadataService {

    nonisolated static func extractMetadata(from url: URL) async -> Track {
        let result = await AudioMetadataReader.read(from: url)

        let pathInfo = parsePathInfo(from: url)
        let fileInfo = parseFilename(url.deletingPathExtension().lastPathComponent)

        let title = result.title ?? fileInfo.title
        let artist = result.artist ?? pathInfo.artist ?? "Unknown Artist"
        let albumTitle = result.albumTitle ?? pathInfo.album ?? "Unknown Album"
        let trackNumber = result.trackNumber > 0 ? result.trackNumber : fileInfo.trackNumber
        let artwork = result.artworkData.flatMap(PlatformImage.init(data:))

        return Track(
            fileURL: url,
            title: title,
            artist: artist,
            albumTitle: albumTitle,
            albumArtist: result.albumArtist,
            trackNumber: trackNumber,
            duration: result.duration,
            artwork: artwork,
            dbID: nil,
            codec: result.codec,
            bitDepth: result.bitDepth,
            sampleRate: result.sampleRate,
            channels: result.channels
        )
    }

    /// What a fresh read of the file says, shaped for refreshing its existing track row.
    nonisolated static func refresh(from url: URL) async -> TrackMetadataRefresh {
        let metadata = await extractMetadata(from: url)
        return TrackMetadataRefresh(
            title: metadata.title,
            artist: metadata.artist,
            albumTitle: metadata.albumTitle,
            albumArtist: metadata.albumArtist,
            trackNumber: metadata.trackNumber,
            duration: metadata.duration,
            artworkData: metadata.artwork?.jpegData(compressionQuality: 0.8),
            codec: metadata.codec,
            bitDepth: metadata.bitDepth,
            sampleRate: metadata.sampleRate,
            channels: metadata.channels
        )
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
        let docsPath = LibraryPaths.root.path
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
}
