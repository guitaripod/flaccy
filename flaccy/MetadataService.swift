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

        let embeddedTitle = await stringValue(for: .commonIdentifierTitle, in: metadata)
        let embeddedArtist = await stringValue(for: .commonIdentifierArtist, in: metadata)
        let embeddedAlbum = await stringValue(for: .commonIdentifierAlbumName, in: metadata)
        let trackNumber = await trackNumberValue(from: metadata)
        let artwork = await artworkImage(from: metadata)

        let pathInfo = parsePathInfo(from: url)
        let fileInfo = parseFilename(url.deletingPathExtension().lastPathComponent)

        let title = embeddedTitle ?? fileInfo.title
        let artist = embeddedArtist ?? pathInfo.artist ?? "Unknown Artist"
        let albumTitle = embeddedAlbum ?? pathInfo.album ?? "Unknown Album"
        let finalTrackNumber = trackNumber > 0 ? trackNumber : fileInfo.trackNumber

        return Track(
            fileURL: url,
            title: title,
            artist: artist,
            albumTitle: albumTitle,
            trackNumber: finalTrackNumber,
            duration: duration,
            artwork: artwork,
            dbID: nil
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
            (#"^(.+?)\s*[-._]\s*(\d{1,3})$"#, 1, 2),
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern.regex),
               let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) {
                if let titleRange = Range(match.range(at: pattern.titleGroup), in: name) {
                    let parsedTitle = String(name[titleRange]).trimmingCharacters(in: .whitespaces)
                    if !parsedTitle.isEmpty {
                        name = parsedTitle
                    }
                }
                if let trackRange = Range(match.range(at: pattern.trackGroup), in: name) {
                    trackNumber = Int(name[trackRange]) ?? 0
                }
                break
            }
        }

        name = name
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
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
