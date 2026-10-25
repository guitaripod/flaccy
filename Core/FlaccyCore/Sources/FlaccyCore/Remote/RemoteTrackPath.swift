import Foundation

/// The path a library row stores for a song that lives on a Subsonic server:
/// `remote://<serverID>/<songID>`, with both parts percent-encoded.
///
/// Local files keep their relative paths, so `isRemote` is the one check that
/// tells the two apart before any file is opened.
///
/// Mirrored in Rust as `linux/shared/src/remote/remote_path.rs`.
public struct RemoteTrackPath: Equatable, Sendable {

    public static let scheme = "remote://"

    public let serverID: String
    public let songID: String

    public init(serverID: String, songID: String) {
        self.serverID = serverID
        self.songID = songID
    }

    /// Parses a stored path; nil unless it is a remote path with exactly two non-empty parts.
    public init?(path: String) {
        guard path.hasPrefix(Self.scheme) else { return nil }
        let parts = path.dropFirst(Self.scheme.count).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let serverID = PercentEscaping.unescape(String(parts[0])),
              let songID = PercentEscaping.unescape(String(parts[1])),
              !serverID.isEmpty, !songID.isEmpty
        else { return nil }
        self.init(serverID: serverID, songID: songID)
    }

    /// The server id as it is written inside `path`, safe as a folder name.
    public var escapedServerID: String { PercentEscaping.escape(serverID) }

    /// The song id as it is written inside `path`, safe as a file name.
    public var escapedSongID: String { PercentEscaping.escape(songID) }

    /// The stored form of this server's song.
    public var path: String {
        Self.scheme + escapedServerID + "/" + escapedSongID
    }

    /// Whether a stored path names a song on a server rather than a local file.
    public static func isRemote(_ path: String) -> Bool {
        path.hasPrefix(scheme)
    }

    /// The scheme of the URL a `Track` carries for a song on a server, which the Apple clients
    /// hand to AVFoundation and a resource loader answers. Apple-only, so Rust has no mirror.
    public static let assetScheme = "flaccy-remote"

    /// The URL a `Track` carries for this song: `flaccy-remote://<serverID>/<songID>`, both parts
    /// percent-encoded exactly as in `path`, so the two spellings convert without loss.
    public var assetURL: URL {
        let string = Self.assetScheme + "://" + path.dropFirst(Self.scheme.count)
        guard let url = URL(string: string) else {
            preconditionFailure("A remote track path built an invalid URL: \(string)")
        }
        return url
    }

    /// Reads the song out of a `Track` URL; nil unless it is a `flaccy-remote` URL naming exactly a server and a song.
    public init?(assetURL: URL) {
        let string = assetURL.absoluteString
        let prefix = Self.assetScheme + "://"
        guard string.hasPrefix(prefix) else { return nil }
        self.init(path: Self.scheme + string.dropFirst(prefix.count))
    }

    /// Whether a URL names a song on a server rather than a file on disk.
    public static func isRemote(assetURL: URL) -> Bool {
        assetURL.scheme == assetScheme
    }
}
