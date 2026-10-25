import Foundation

/// Decodes the JSON a Subsonic server answers with into one envelope type.
///
/// Every payload is optional because a server answers only the call that was made, and
/// unknown fields are ignored so newer servers still decode. The fields a sync or playback
/// path depends on are typed; the rest of the protocol is left out on purpose.
///
/// Mirrored in Rust as `linux/shared/src/remote/subsonic_response.rs`, decoded from the same
/// fixtures in `Tests/FlaccyCoreTests/Fixtures/Subsonic`.
public enum SubsonicResponse {

    /// The object under `subsonic-response`.
    public struct Envelope: Decodable, Equatable, Sendable {
        public let status: String
        public let version: String?
        public let type: String?
        public let serverVersion: String?
        public let openSubsonic: Bool?
        public let error: ServerError?
        public let openSubsonicExtensions: [OpenSubsonicExtension]?
        public let musicFolders: MusicFolders?
        public let artists: ArtistsPayload?
        public let albumList2: AlbumList2?
        public let album: AlbumWithSongs?
        public let song: Child?
        public let searchResult3: SearchResult3?
        public let playlists: PlaylistsPayload?

        /// The typed failure when the server answered `failed`; nil for a successful answer.
        public var failure: SubsonicFailure? {
            guard status == "failed" else { return nil }
            return SubsonicFailure(code: error?.code ?? 0)
        }

        /// Whether the server lists an OpenSubsonic extension under this name.
        public func supports(extension name: String) -> Bool {
            openSubsonicExtensions?.contains { $0.name == name } ?? false
        }
    }

    public struct ServerError: Decodable, Equatable, Sendable {
        public let code: Int?
        public let message: String?
    }

    public struct OpenSubsonicExtension: Decodable, Equatable, Sendable {
        public let name: String
        public let versions: [Int]?
    }

    public struct MusicFolders: Decodable, Equatable, Sendable {
        public let musicFolder: [MusicFolder]?
    }

    public struct MusicFolder: Decodable, Equatable, Sendable {
        public let id: Int?
        public let name: String?
    }

    public struct ArtistsPayload: Decodable, Equatable, Sendable {
        public let index: [ArtistIndex]?
    }

    public struct ArtistIndex: Decodable, Equatable, Sendable {
        public let name: String?
        public let artist: [Artist]?
    }

    public struct Artist: Decodable, Equatable, Sendable {
        public let id: String?
        public let name: String?
        public let albumCount: Int?
        public let coverArt: String?
    }

    public struct AlbumList2: Decodable, Equatable, Sendable {
        public let album: [AlbumID3]?
    }

    public struct AlbumID3: Decodable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let artist: String?
        public let artistId: String?
        public let coverArt: String?
        public let songCount: Int?
        public let duration: Double?
        public let created: String?
        public let year: Int?
        public let genre: String?
        public let displayArtist: String?
    }

    /// An album from `getAlbum`: its `AlbumID3` fields beside its `song` list.
    public struct AlbumWithSongs: Decodable, Equatable, Sendable {
        public let album: AlbumID3
        public let song: [Child]?

        public init(from decoder: Decoder) throws {
            album = try AlbumID3(from: decoder)
            song = try decoder.container(keyedBy: SongKey.self).decodeIfPresent([Child].self, forKey: .song)
        }

        private enum SongKey: String, CodingKey {
            case song
        }
    }

    /// A song, as `song`, `search3` and album listings describe it. The three `flaccy*` fields
    /// come from Flaccy's own server and are absent on a server that does not run it.
    public struct Child: Decodable, Equatable, Sendable {
        public let id: String
        public let parent: String?
        public let title: String
        public let album: String?
        public let artist: String?
        public let track: Int?
        public let discNumber: Int?
        public let year: Int?
        public let genre: String?
        public let coverArt: String?
        public let size: Int64?
        public let contentType: String?
        public let suffix: String?
        public let duration: Double?
        public let bitRate: Int?
        public let bitDepth: Int?
        public let samplingRate: Int?
        public let channelCount: Int?
        public let path: String?
        public let albumId: String?
        public let artistId: String?
        public let type: String?
        public let created: String?
        public let musicBrainzId: String?
        public let displayArtist: String?
        public let displayAlbumArtist: String?
        public let flaccyFingerprint: String?
        public let flaccyRevision: Int?
        public let flaccyRevisedAt: String?
    }

    public struct SearchResult3: Decodable, Equatable, Sendable {
        public let artist: [Artist]?
        public let album: [AlbumID3]?
        public let song: [Child]?
    }

    public struct PlaylistsPayload: Decodable, Equatable, Sendable {
        public let playlist: [Playlist]?
    }

    public struct Playlist: Decodable, Equatable, Sendable {
        public let id: String?
        public let name: String?
        public let songCount: Int?
        public let duration: Double?
        public let created: String?
        public let changed: String?
        public let coverArt: String?
        public let owner: String?
        public let isPublic: Bool?

        private enum CodingKeys: String, CodingKey {
            case id, name, songCount, duration, created, changed, coverArt, owner
            case isPublic = "public"
        }
    }

    private struct Root: Decodable {
        let response: Envelope

        private enum CodingKeys: String, CodingKey {
            case response = "subsonic-response"
        }
    }

    /// Decodes one response body. Bytes that are not a `subsonic-response` object throw.
    public static func decode(_ data: Data) throws -> Envelope {
        try JSONDecoder().decode(Root.self, from: data).response
    }
}
