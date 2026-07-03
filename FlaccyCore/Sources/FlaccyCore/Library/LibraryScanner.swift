import Foundation

/// Scans a directory tree for audio files and builds `MediaItem`s / `MediaAlbum`s.
/// Used by the standalone watch app to index whatever audio has been side-loaded
/// into its sandbox.
public enum LibraryScanner {

    public static let supportedExtensions: Set<String> =
        ["flac", "m4a", "aac", "alac", "mp3", "wav", "aiff", "aif", "caf"]

    /// Recursively scans `directory`, reading metadata for every supported file.
    /// `relativePath`s are computed against `directory`.
    public static func scan(directory: URL) async -> [MediaItem] {
        let urls = collectAudioFiles(in: directory)
        let basePath = directory.standardizedFileURL.path
        let maxConcurrent = max(2, ProcessInfo.processInfo.activeProcessorCount)

        var items: [MediaItem] = []
        items.reserveCapacity(urls.count)

        await withTaskGroup(of: MediaItem?.self) { group in
            var next = 0
            while next < urls.count, next < maxConcurrent {
                let url = urls[next]
                group.addTask { await makeItem(url: url, basePath: basePath) }
                next += 1
            }
            for await item in group {
                if let item { items.append(item) }
                if next < urls.count {
                    let url = urls[next]
                    group.addTask { await makeItem(url: url, basePath: basePath) }
                    next += 1
                }
            }
        }
        return items
    }

    private static func makeItem(url: URL, basePath: String) async -> MediaItem {
        let metadata = await AudioMetadataReader.read(from: url)
        let relativePath = relativePath(of: url, basePath: basePath)
        let fallback = FilenameParser.parse(url.deletingPathExtension().lastPathComponent)
        let path = pathInfo(relativePath: relativePath)
        return MediaItem(
            relativePath: relativePath,
            title: metadata.title ?? fallback.title,
            artist: metadata.artist ?? path.artist ?? "Unknown Artist",
            albumTitle: metadata.albumTitle ?? path.album ?? "Unknown Album",
            trackNumber: metadata.trackNumber > 0 ? metadata.trackNumber : fallback.trackNumber,
            duration: metadata.duration,
            artworkData: metadata.artworkData
        )
    }

    /// Groups items into albums sorted by artist/title, tracks sorted by number.
    public static func albums(from items: [MediaItem]) -> [MediaAlbum] {
        let grouped = Dictionary(grouping: items) { "\($0.albumTitle)|\($0.artist)" }
        let albums: [MediaAlbum] = grouped.values.compactMap { group in
            guard let first = group.first else { return nil }
            let sorted = group.sorted { $0.trackNumber < $1.trackNumber }
            return MediaAlbum(title: first.albumTitle, artist: first.artist, items: sorted)
        }
        return albums.sorted(by: Self.albumOrder)
    }

    private static func albumOrder(_ lhs: MediaAlbum, _ rhs: MediaAlbum) -> Bool {
        let artistComparison = lhs.artist.localizedCaseInsensitiveCompare(rhs.artist)
        if artistComparison != .orderedSame {
            return artistComparison == .orderedAscending
        }
        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }

    /// Relative paths of every supported audio file under `directory`.
    /// Used by the watch to acknowledge exactly what it currently holds.
    public static func audioFileRelativePaths(in directory: URL) -> [String] {
        let basePath = directory.standardizedFileURL.path
        return collectAudioFiles(in: directory).map { relativePath(of: $0, basePath: basePath) }
    }

    private static func collectAudioFiles(in directory: URL) -> [URL] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var urls: [URL] = []
        for case let url as URL in enumerator {
            guard supportedExtensions.contains(url.pathExtension.lowercased()) else { continue }
            urls.append(url)
        }
        return urls
    }

    private static func pathInfo(relativePath: String) -> (artist: String?, album: String?) {
        let components = relativePath
            .split(separator: "/")
            .dropLast()
            .map(String.init)
        switch components.count {
        case 0: return (nil, nil)
        case 1: return (nil, components[0])
        default: return (components[components.count - 2], components[components.count - 1])
        }
    }

    private static func relativePath(of url: URL, basePath: String) -> String {
        let filePath = url.standardizedFileURL.path
        guard filePath.hasPrefix(basePath) else { return canonicalSyncPath(url.lastPathComponent) }
        let relative = String(filePath.dropFirst(basePath.count))
        return canonicalSyncPath(relative.hasPrefix("/") ? String(relative.dropFirst()) : relative)
    }
}

/// Best-effort title/track-number recovery from a filename when tags are missing.
public enum FilenameParser {

    public struct Parsed: Sendable {
        public let title: String
        public let trackNumber: Int
    }

    public static func parse(_ filename: String) -> Parsed {
        var name = filename
        var trackNumber = 0

        let patterns: [(regex: String, titleGroup: Int, trackGroup: Int)] = [
            (#"^(\d{1,3})\s*[-._)\]]\s*(.+)$"#, 2, 1),
            (#"^(\d{1,3})\s+(.+)$"#, 2, 1),
        ]

        let original = name
        for pattern in patterns {
            guard
                let regex = try? NSRegularExpression(pattern: pattern.regex),
                let match = regex.firstMatch(in: original, range: NSRange(original.startIndex..., in: original))
            else { continue }

            if let trackRange = Range(match.range(at: pattern.trackGroup), in: original) {
                trackNumber = Int(original[trackRange]) ?? 0
            }
            if let titleRange = Range(match.range(at: pattern.titleGroup), in: original) {
                let parsed = String(original[titleRange]).trimmingCharacters(in: .whitespaces)
                if !parsed.isEmpty { name = parsed }
            }
            break
        }

        name = name
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)

        return Parsed(title: name.isEmpty ? filename : name, trackNumber: trackNumber)
    }
}
