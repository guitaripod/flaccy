import FlaccyCore
import Foundation
import UIKit

enum MetadataService {

    nonisolated static func extractMetadata(from url: URL) async -> Track {
        let result = await AudioMetadataReader.read(from: url)

        let pathInfo = parsePathInfo(from: url)
        let fileInfo = parseFilename(url.deletingPathExtension().lastPathComponent)

        let title = result.title ?? fileInfo.title
        let artist = result.artist ?? pathInfo.artist ?? "Unknown Artist"
        let albumTitle = result.albumTitle ?? pathInfo.album ?? "Unknown Album"
        let trackNumber = result.trackNumber > 0 ? result.trackNumber : fileInfo.trackNumber
        let artwork = result.artworkData.flatMap(UIImage.init(data:))

        return Track(
            fileURL: url,
            title: title,
            artist: artist,
            albumTitle: albumTitle,
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
}
