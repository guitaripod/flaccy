import Foundation

/// Decides what a sync does to the local rows of one server, given the server's current catalog.
///
/// A song is a new version when its audio changed: when both sides carry a fingerprint, the
/// fingerprints differ; otherwise the size differs or the duration moves by more than half a
/// second. A song whose audio is unchanged but whose title, artist, album or track differs is
/// `updated`. A new version is never also `updated`, and the fingerprint decides audio
/// identity even when the size changed.
///
/// Mirrored in Rust as `linux/shared/src/remote/catalog_diff.rs`.
public enum RemoteCatalogDiff {

    /// One song as the server or a local row describes it.
    public struct Item: Equatable, Sendable {
        public let id: String
        public let size: Int64?
        public let duration: Double?
        public let title: String?
        public let artist: String?
        public let album: String?
        public let track: Int?
        public let fingerprint: String?

        public init(
            id: String,
            size: Int64?,
            duration: Double?,
            title: String?,
            artist: String?,
            album: String?,
            track: Int?,
            fingerprint: String?
        ) {
            self.id = id
            self.size = size
            self.duration = duration
            self.title = title
            self.artist = artist
            self.album = album
            self.track = track
            self.fingerprint = fingerprint
        }
    }

    public struct Result: Equatable, Sendable {
        /// Server ids with no local row, in server order.
        public let inserted: [String]
        /// Local ids the server no longer lists, sorted.
        public let removed: [String]
        /// Ids whose metadata changed while their audio did not.
        public let updated: [String]
        /// Ids whose audio changed.
        public let newVersions: [String]
    }

    /// Compares the server's songs with the local rows of that server.
    public static func diff(server: [Item], local: [Item]) -> Result {
        let localByID = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let serverIDs = Set(server.map(\.id))
        var inserted: [String] = []
        var updated: [String] = []
        var newVersions: [String] = []
        for song in server {
            guard let row = localByID[song.id] else {
                inserted.append(song.id)
                continue
            }
            if isNewVersion(server: song, local: row) {
                newVersions.append(song.id)
            } else if hasMetadataChanged(server: song, local: row) {
                updated.append(song.id)
            }
        }
        let removed = local.map(\.id).filter { !serverIDs.contains($0) }.sorted()
        return Result(inserted: inserted, removed: removed, updated: updated, newVersions: newVersions)
    }

    private static func isNewVersion(server: Item, local: Item) -> Bool {
        if let serverFingerprint = server.fingerprint, let localFingerprint = local.fingerprint {
            return serverFingerprint != localFingerprint
        }
        return server.size != local.size || durationMoved(server.duration, local.duration)
    }

    private static func durationMoved(_ server: Double?, _ local: Double?) -> Bool {
        if let server, let local {
            return abs(server - local) > 0.5
        }
        return server != local
    }

    private static func hasMetadataChanged(server: Item, local: Item) -> Bool {
        server.title != local.title
            || server.artist != local.artist
            || server.album != local.album
            || server.track != local.track
    }
}
