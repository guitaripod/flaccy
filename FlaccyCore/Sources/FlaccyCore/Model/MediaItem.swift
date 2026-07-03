import Foundation

/// Platform-agnostic, `Codable` representation of a playable track.
///
/// This is the lingua franca between persistence, the audio engines, and the
/// watch <-> phone connectivity layer. Artwork is carried as raw `Data` so the
/// model stays free of UIKit; each UI layer decodes it into its own image type.
public struct MediaItem: Codable, Sendable, Hashable, Identifiable {

    public var id: String { relativePath }

    /// Path relative to the app's Documents directory. Stable across launches
    /// and portable between the phone and the watch sandboxes.
    public let relativePath: String
    public let title: String
    public let artist: String
    public let albumTitle: String
    public let trackNumber: Int
    public let duration: TimeInterval
    public let artworkData: Data?

    public init(
        relativePath: String,
        title: String,
        artist: String,
        albumTitle: String,
        trackNumber: Int,
        duration: TimeInterval,
        artworkData: Data? = nil
    ) {
        self.relativePath = relativePath
        self.title = title
        self.artist = artist
        self.albumTitle = albumTitle
        self.trackNumber = trackNumber
        self.duration = duration
        self.artworkData = artworkData
    }

    public static func == (lhs: MediaItem, rhs: MediaItem) -> Bool {
        lhs.relativePath == rhs.relativePath
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(relativePath)
    }

    /// Resolves the absolute file URL within the given documents directory.
    public func fileURL(in documentsDirectory: URL) -> URL {
        documentsDirectory.appendingPathComponent(relativePath)
    }
}

/// A group of `MediaItem`s sharing an album + artist, ordered by track number.
public struct MediaAlbum: Identifiable, Sendable, Hashable {

    public var id: String { "\(title)|\(artist)" }

    public let title: String
    public let artist: String
    public let items: [MediaItem]

    public init(title: String, artist: String, items: [MediaItem]) {
        self.title = title
        self.artist = artist
        self.items = items
    }

    public var artworkData: Data? {
        items.first(where: { $0.artworkData != nil })?.artworkData
    }

    public var totalDuration: TimeInterval {
        items.reduce(0) { $0 + $1.duration }
    }
}
