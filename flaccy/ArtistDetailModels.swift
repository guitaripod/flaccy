import UIKit

nonisolated enum ArtistDetailItem: Hashable, Sendable {
    case header(ArtistHeaderInfo)
    case similarAlbum(SimilarAlbumItem)
    case popularTrack(PopularTrackItem)
    case album(Album)
    case message(DetailMessageItem)
}

nonisolated struct SimilarAlbumItem: Hashable, Sendable {
    let album: Album
}

nonisolated struct PopularTrackItem: Hashable, Sendable {
    let name: String
    let playCount: Int
    let rank: Int
    let ownedTrack: Track?

    nonisolated static func == (lhs: PopularTrackItem, rhs: PopularTrackItem) -> Bool {
        lhs.rank == rhs.rank && lhs.name == rhs.name
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(rank)
    }
}

nonisolated struct DetailMessageItem: Hashable, Sendable {
    let id: String
    let text: String
    let isLoading: Bool
}

nonisolated struct ArtistHeaderInfo: Hashable, Sendable {
    let name: String
    let bio: String?
    let genre: String?
    let albumCount: Int
    let trackCount: Int
    let artwork: UIImage?
    let firstAlbumTitle: String?
    var genres: [String] = []

    nonisolated static func == (lhs: ArtistHeaderInfo, rhs: ArtistHeaderInfo) -> Bool {
        lhs.name == rhs.name && lhs.genres == rhs.genres
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(name)
    }
}
