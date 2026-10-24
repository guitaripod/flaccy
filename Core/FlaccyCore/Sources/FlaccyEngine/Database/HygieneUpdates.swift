import Foundation
import FlaccyCore

public struct AlbumRetitle: Sendable {
    public let fromTitle: String
    public let fromArtist: String
    public let toTitle: String
    public let toArtist: String

    public init(
        fromTitle: String,
        fromArtist: String,
        toTitle: String,
        toArtist: String
    ) {
        self.fromTitle = fromTitle
        self.fromArtist = fromArtist
        self.toTitle = toTitle
        self.toArtist = toArtist
    }
}

public struct KeeperUpdate: Sendable {
    public let relativePath: String
    public let loved: Bool
    public let playCount: Int

    public init(
        relativePath: String,
        loved: Bool,
        playCount: Int
    ) {
        self.relativePath = relativePath
        self.loved = loved
        self.playCount = playCount
    }
}

public struct AlbumInfoMerge: Sendable {
    public let canonicalTitle: String
    public let canonicalArtist: String
    public let variants: [LibraryHygiene.AlbumVariant]

    public init(
        canonicalTitle: String,
        canonicalArtist: String,
        variants: [LibraryHygiene.AlbumVariant]
    ) {
        self.canonicalTitle = canonicalTitle
        self.canonicalArtist = canonicalArtist
        self.variants = variants
    }
}
