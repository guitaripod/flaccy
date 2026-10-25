import AVFoundation
import CryptoKit
import FlaccyCore
import Foundation
import ImageIO

/// One picture a person can pick as a release's cover without leaving their
/// own disk: an image lying beside the music, or art embedded in a track.
nonisolated struct LocalArtworkItem: @unchecked Sendable, Identifiable {

    enum Origin: Sendable {
        case file(URL)
        case embedded(Data)
    }

    let id: String
    let origin: Origin
    let label: String
    let pixelWidth: Int
    let pixelHeight: Int
    let thumbnail: CGImage?

    /// The full bytes, read only when the person actually picks the picture.
    func loadData() throws -> Data {
        switch origin {
        case .file(let url): try Data(contentsOf: url)
        case .embedded(let data): data
        }
    }
}

/// Finds the pictures that belong to a release on the person's own disk. The
/// rules for which images count and in what order live in `ArtworkLocalRules`;
/// this is the file access and the tag reading around them, both meant to run
/// off the main thread.
nonisolated enum LocalArtworkFinder {

    static let maximumEmbedded = 8
    static let thumbnailPixels: CGFloat = 360

    /// Images lying in the release's folders, front covers first. The library
    /// root itself is never searched, because pictures there belong to no
    /// particular release.
    static func folderImages(
        for album: Album, root: URL = LibraryPaths.root, fileManager: FileManager = .default
    ) -> [LocalArtworkItem] {
        let relatives = relativePaths(of: album.tracks.map(\.fileURL), under: root)
        var items: [LocalArtworkItem] = []
        for folder in ArtworkLocalRules.folders(forRelativePaths: relatives) {
            let directory = root.appendingPathComponent(folder, isDirectory: true)
            let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
            for name in ArtworkLocalRules.rank(names) {
                let url = directory.appendingPathComponent(name)
                guard fileSize(of: url, fileManager: fileManager) <= ArtworkLocalRules.maximumFileBytes,
                      let item = item(forFile: url, label: name, id: "file-\(folder)/\(name)")
                else { continue }
                items.append(item)
            }
        }
        return items
    }

    /// Distinct pictures embedded in the release's tracks, in the order the
    /// tracks come, at most `maximumEmbedded`. The database no longer keeps
    /// per-track art, so each file is asked directly; a release whose tracks
    /// all carry the same picture yields one.
    static func embeddedImages(for album: Album) async -> [LocalArtworkItem] {
        var seen = Set<String>()
        var items: [LocalArtworkItem] = []
        let ordered = album.tracks.sorted {
            ($0.trackNumber, $0.fileURL.path) < ($1.trackNumber, $1.fileURL.path)
        }
        for (index, track) in ordered.enumerated() {
            if Task.isCancelled || items.count >= maximumEmbedded { break }
            guard let readable = RemoteStreamCache.shared.readableFile(for: track.fileURL) else { continue }
            for data in await embeddedPictures(in: readable) {
                guard items.count < maximumEmbedded, seen.insert(contentHash(of: data)).inserted else { continue }
                let number = track.trackNumber > 0 ? track.trackNumber : index + 1
                guard let item = item(
                    forData: data, label: String(localized: "Track \(number)"), id: "embedded-\(items.count)"
                ) else { continue }
                items.append(item)
            }
        }
        return items
    }

    /// The covers of the releases a playlist draws from, one per distinct
    /// album in playlist order, labelled with the album's title. They come
    /// from the database's hoisted covers, so nothing is read off the disk.
    static func playlistAlbumCovers(for subject: ArtworkSubject) -> [LocalArtworkItem] {
        let albums = PlaylistCover.shelfAlbums(subject.tracks.map { (title: $0.albumTitle, artist: $0.artist) })
        var seen = Set<String>()
        var items: [LocalArtworkItem] = []
        for album in albums {
            guard let data = try? DatabaseManager.shared.fetchAlbumArtwork(title: album.title, artist: album.artist),
                  seen.insert(contentHash(of: data)).inserted,
                  let item = item(forData: data, label: album.title, id: "playlist-album-\(items.count)")
            else { continue }
            items.append(item)
        }
        return items
    }

    static func relativePaths(of fileURLs: [URL], under root: URL) -> [String] {
        let prefix = root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        return fileURLs.compactMap { url in
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : nil
        }
    }

    static func contentHash(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func embeddedPictures(in fileURL: URL) async -> [Data] {
        let asset = AVURLAsset(url: fileURL)
        guard let metadata = try? await asset.load(.metadata) else { return [] }
        var pictures: [Data] = []
        for entry in AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierArtwork) {
            if let data = try? await entry.load(.dataValue), !data.isEmpty { pictures.append(data) }
        }
        return pictures
    }

    private static func fileSize(of url: URL, fileManager: FileManager) -> Int {
        ((try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? .max
    }

    private static func item(forFile url: URL, label: String, id: String) -> LocalArtworkItem? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        return item(from: source, origin: .file(url), label: label, id: id)
    }

    private static func item(forData data: Data, label: String, id: String) -> LocalArtworkItem? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        return item(from: source, origin: .embedded(data), label: label, id: id)
    }

    private static func item(
        from source: CGImageSource, origin: LocalArtworkItem.Origin, label: String, id: String
    ) -> LocalArtworkItem? {
        guard let size = pixelSize(of: source) else { return nil }
        let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailPixels,
        ] as CFDictionary)
        return LocalArtworkItem(
            id: id, origin: origin, label: label,
            pixelWidth: size.width, pixelHeight: size.height, thumbnail: thumbnail
        )
    }

    /// Pixel size from the header alone, turned the way the picture is shown
    /// when its orientation tag says it lies on its side.
    private static func pixelSize(of source: CGImageSource) -> (width: Int, height: Int)? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else { return nil }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? (height, width) : (width, height)
    }
}
