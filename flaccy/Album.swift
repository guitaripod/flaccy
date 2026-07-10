import Foundation

nonisolated struct Album: Sendable, Hashable, Identifiable {

    var id: String { "\(title)|\(artist)" }

    let title: String
    let artist: String
    let artwork: PlatformImage?
    let tracks: [Track]
    let year: String?
    let genre: String?

    static func == (lhs: Album, rhs: Album) -> Bool {
        lhs.title == rhs.title && lhs.artist == rhs.artist
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(title)
        hasher.combine(artist)
    }
}
