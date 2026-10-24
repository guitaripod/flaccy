import Foundation

/// How a playlist's cover is addressed and which albums stand in for it. A
/// playlist's chosen picture is served by the same artwork cache and editor as
/// an album's, so it is addressed by a reserved (title, artist) pair no album
/// can carry: the artist half starts with a control character that no tag
/// holds. Mirrored in Rust as `linux/shared/src/playlist_cover.rs`.
public enum PlaylistCover {

    public static let artist = "\u{1}playlist"

    public static let maximumMosaicTiles = 4

    public static let maximumShelfAlbums = 12

    private static let titlePrefix = "playlist:"

    public static func title(forPlaylist id: Int64) -> String {
        "\(titlePrefix)\(id)"
    }

    /// The playlist a cache key names, or nil for an ordinary album key.
    public static func playlistId(title: String, artist: String) -> Int64? {
        guard artist == Self.artist, title.hasPrefix(titlePrefix) else { return nil }
        return Int64(title.dropFirst(titlePrefix.count))
    }

    /// The albums whose covers make up the automatic mosaic: the first
    /// distinct releases in playlist order, at most four.
    public static func mosaicAlbums(_ albums: [(title: String, artist: String)]) -> [(title: String, artist: String)] {
        distinct(albums, limit: maximumMosaicTiles)
    }

    /// The albums offered as ready-made covers in the editor's shelf: the
    /// distinct releases in playlist order, at most twelve.
    public static func shelfAlbums(_ albums: [(title: String, artist: String)]) -> [(title: String, artist: String)] {
        distinct(albums, limit: maximumShelfAlbums)
    }

    private static func distinct(
        _ albums: [(title: String, artist: String)], limit: Int
    ) -> [(title: String, artist: String)] {
        var seen = Set<String>()
        var kept: [(title: String, artist: String)] = []
        for album in albums where !album.title.isEmpty {
            guard seen.insert("\(album.title)\u{0}\(album.artist)").inserted else { continue }
            kept.append(album)
            if kept.count == limit { break }
        }
        return kept
    }
}
