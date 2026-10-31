import FlaccyCore
import FlaccyEngine
import MidgarCore
import Foundation

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

enum MetadataService {

    nonisolated static func extractMetadata(from url: URL) async -> Track {
        await extractMetadata(from: url, wantsArtwork: { _, _ in true })
    }

    /// Reads the file's tags, loading its picture only when `wantsArtwork`
    /// asks for it with the album title and artist the track will be filed
    /// under (the tags, or the folders and the "Unknown" names standing in).
    nonisolated static func extractMetadata(
        from url: URL,
        wantsArtwork: @escaping @Sendable (_ albumTitle: String, _ artist: String) -> Bool
    ) async -> Track {
        let pathInfo = parsePathInfo(from: url)
        let result = await AudioMetadataReader.read(from: url) { albumTitle, artist in
            wantsArtwork(
                albumTitle ?? pathInfo.album ?? unknownAlbum,
                artist ?? pathInfo.artist ?? unknownArtist
            )
        }

        let fileInfo = parseFilename(url.deletingPathExtension().lastPathComponent)

        let title = result.title ?? fileInfo.title
        let artist = result.artist ?? pathInfo.artist ?? unknownArtist
        let albumTitle = result.albumTitle ?? pathInfo.album ?? unknownAlbum
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

    /// Reads the tags as `extractMetadata(from:wantsArtwork:)` does, or files
    /// the song under what its name and folders say once `limit` passes, so a
    /// file the decoder cannot get through never holds a scan up.
    nonisolated static func extractMetadata(
        from url: URL,
        within limit: Duration,
        wantsArtwork: @escaping @Sendable (_ albumTitle: String, _ artist: String) -> Bool
    ) async -> Track {
        if let read = await Deadline.value(within: limit, { await extractMetadata(from: url, wantsArtwork: wantsArtwork) }) {
            return read
        }
        MidgarLog.notice(
            "Tags of \(url.lastPathComponent) were not read within \(limit); filed by its name and folders",
            category: .content
        )
        return metadataFromPath(of: url)
    }

    /// A track built from the file's name and the folders it sits in, with the
    /// format read from its header, for a file whose tags could not be read.
    nonisolated static func metadataFromPath(of url: URL) -> Track {
        let pathInfo = parsePathInfo(from: url)
        let fileInfo = parseFilename(url.deletingPathExtension().lastPathComponent)
        let format = AudioMetadataReader.readFormat(from: url)
        return Track(
            fileURL: url,
            title: fileInfo.title,
            artist: pathInfo.artist ?? unknownArtist,
            albumTitle: pathInfo.album ?? unknownAlbum,
            albumArtist: nil,
            trackNumber: fileInfo.trackNumber,
            duration: 0,
            artwork: nil,
            dbID: nil,
            codec: format.codec,
            bitDepth: format.bitDepth,
            sampleRate: format.sampleRate,
            channels: format.channels
        )
    }

    nonisolated private static let unknownArtist = "Unknown Artist"
    nonisolated private static let unknownAlbum = "Unknown Album"

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
