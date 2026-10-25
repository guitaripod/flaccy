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

    /// The stored form of this server's song.
    public var path: String {
        Self.scheme + PercentEscaping.escape(serverID) + "/" + PercentEscaping.escape(songID)
    }

    /// Whether a stored path names a song on a server rather than a local file.
    public static func isRemote(_ path: String) -> Bool {
        path.hasPrefix(scheme)
    }
}
