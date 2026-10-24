import Combine
import MidgarCore
import FlaccyCore

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

nonisolated enum LibraryItem: Hashable, Sendable {
    case album(Album)
    case recentAlbum(Album)
    case song(Track)
    case artist(ArtistItem)
    case playlist(PlaylistItem)
    case suggestedPlaylist(SuggestedPlaylist)
    case charts
    case wantlist

    /// The identity a diffable snapshot keys an album row by: the earliest file
    /// path the album owns, which no amount of retitling moves.
    ///
    /// Keying by title and artist — which is what `Album`'s own `Hashable` does
    /// — would make every AI correction during the Debut's second act a delete
    /// followed by an insert, and the grid would tear under a reader who is
    /// already scrolling it. Keyed by a path, the same correction is a move.
    nonisolated static func identity(of album: Album) -> String {
        album.tracks.lazy.map(\.fileURL.absoluteString).min() ?? album.id
    }

    /// What a row draws, so a snapshot can ask for a reconfigure when the
    /// identity held but the words on screen changed.
    nonisolated static func renderSignature(of album: Album) -> String {
        "\(album.title)\u{1F}\(album.artist)\u{1F}\(album.year ?? "")\u{1F}\(album.genre ?? "")"
    }

    nonisolated static func == (lhs: LibraryItem, rhs: LibraryItem) -> Bool {
        switch (lhs, rhs) {
        case (.album(let a), .album(let b)), (.recentAlbum(let a), .recentAlbum(let b)):
            return identity(of: a) == identity(of: b)
        case (.song(let a), .song(let b)): return a == b
        case (.artist(let a), .artist(let b)): return a == b
        case (.playlist(let a), .playlist(let b)): return a == b
        case (.suggestedPlaylist(let a), .suggestedPlaylist(let b)): return a == b
        case (.charts, .charts), (.wantlist, .wantlist): return true
        default: return false
        }
    }

    nonisolated func hash(into hasher: inout Hasher) {
        switch self {
        case .album(let album):
            hasher.combine(0)
            hasher.combine(Self.identity(of: album))
        case .recentAlbum(let album):
            hasher.combine(1)
            hasher.combine(Self.identity(of: album))
        case .song(let track):
            hasher.combine(2)
            hasher.combine(track)
        case .artist(let artist):
            hasher.combine(3)
            hasher.combine(artist)
        case .playlist(let playlist):
            hasher.combine(4)
            hasher.combine(playlist)
        case .suggestedPlaylist(let suggestion):
            hasher.combine(5)
            hasher.combine(suggestion)
        case .charts:
            hasher.combine(6)
        case .wantlist:
            hasher.combine(7)
        }
    }
}

nonisolated struct ArtistItem: Hashable, Sendable {
    let name: String
    let albumCount: Int
    /// Albums this artist performs on without being the credit — a composer on
    /// a Various Artists soundtrack, a guest on somebody else's record. Kept
    /// apart from `albumCount` so a performer is never sold as an author.
    let appearanceCount: Int
    let artwork: PlatformImage?

    nonisolated static func == (lhs: ArtistItem, rhs: ArtistItem) -> Bool {
        lhs.name == rhs.name
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(name)
    }
}

nonisolated struct PlaylistItem: Hashable, Sendable {
    let id: Int64
    let name: String
    let trackCount: Int

    nonisolated static func == (lhs: PlaylistItem, rhs: PlaylistItem) -> Bool {
        lhs.id == rhs.id
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
