import Foundation

/// Pairs the songs on this device with the copies a server holds, so the device can play the
/// server's copy in their place and keep everything that belongs to them.
///
/// A song only ever matches a server song with the same song key, so everything keyed by it (loves,
/// song volumes, synced playlist entries) stays attached. Among those it matches one that carries the
/// same audio fingerprint; or one on the same album that lasts within `durationToleranceMs` of it; or,
/// on another album, one with the same track number within `otherAlbumToleranceMs`, which catches a
/// copy whose album title only differs by a disc or edition suffix while a live or edited take, which
/// runs differently, stays. Each server song takes one song from the device as its pair, chosen by the
/// same audio first, then the same album, then the same track number, then the copy the person uses
/// most (`rank`, so the copy on the watch keeps its place there), then the closest length, then the
/// lowest paths, so the result never depends on the order the songs arrive in. A further copy on the device that matches a
/// server song already taken is a duplicate of that pair. A song that matches nothing stays on
/// the device.
///
/// The keys are opaque here: callers pass the song key the sync uses (lead artist and title) and
/// the album key of the listen history, computed the same way on both sides.
///
/// Mirrored in Rust as `linux/shared/src/remote/server_move.rs`.
public enum ServerMovePlan {

    public static let durationToleranceMs: Int64 = 2_000
    /// A server stores whole seconds and AAC adds a few milliseconds, so a transcode of the same file
    /// lands within a second.
    public static let otherAlbumToleranceMs: Int64 = 1_000

    public struct Song: Equatable, Sendable {
        public let path: String
        public let songKey: String
        public let albumKey: String
        public let track: Int
        public let durationMs: Int64
        public let fingerprint: String?
        /// How much the person uses this copy; among copies on the device, the higher one becomes the pair.
        public let rank: Int

        public init(
            path: String, songKey: String, albumKey: String, track: Int, durationMs: Int64, fingerprint: String?, rank: Int = 0
        ) {
            self.path = path
            self.songKey = songKey
            self.albumKey = albumKey
            self.track = track
            self.durationMs = durationMs
            self.fingerprint = fingerprint
            self.rank = rank
        }
    }

    public struct Pair: Equatable, Hashable, Sendable {
        public let local: String
        public let server: String

        public init(local: String, server: String) {
            self.local = local
            self.server = server
        }
    }

    public struct Result: Equatable, Sendable {
        /// One song from the device for each server song it matched, sorted by the path on the device.
        public let pairs: [Pair]
        /// Further copies on the device of a server song that already has its pair, sorted the same way.
        public let duplicates: [Pair]
        /// The paths of the songs no server song matched, sorted.
        public let unmatched: [String]
    }

    private enum Kind: Int {
        case sameAudio
        case sameAlbum
        case sameTrack
    }

    private struct Edge {
        let local: Int
        let server: Int
        let kind: Kind
        let sameTrack: Bool
        let gapMs: Int64
    }

    public static func plan(local: [Song], server: [Song]) -> Result {
        let edges = candidateEdges(local: local, server: server)
            .sorted { isPreferred($0, over: $1, local: local, server: server) }
        var takenLocal = Set<Int>()
        var takenServer = Set<Int>()
        var pairs: [Pair] = []
        for edge in edges where !takenLocal.contains(edge.local) && !takenServer.contains(edge.server) {
            takenLocal.insert(edge.local)
            takenServer.insert(edge.server)
            pairs.append(Pair(local: local[edge.local].path, server: server[edge.server].path))
        }
        var duplicates: [Pair] = []
        for edge in edges where !takenLocal.contains(edge.local) {
            takenLocal.insert(edge.local)
            duplicates.append(Pair(local: local[edge.local].path, server: server[edge.server].path))
        }
        pairs.sort { $0.local < $1.local }
        duplicates.sort { $0.local < $1.local }
        let unmatched = local.indices.filter { !takenLocal.contains($0) }.map { local[$0].path }.sorted()
        return Result(pairs: pairs, duplicates: duplicates, unmatched: unmatched)
    }

    private static func candidateEdges(local: [Song], server: [Song]) -> [Edge] {
        var byFingerprint: [String: [Int]] = [:]
        var bySongKey: [String: [Int]] = [:]
        for (index, song) in server.enumerated() {
            if let fingerprint = nonEmpty(song.fingerprint) { byFingerprint[fingerprint, default: []].append(index) }
            if !song.songKey.isEmpty { bySongKey[song.songKey, default: []].append(index) }
        }
        var edges: [Edge] = []
        for (localIndex, song) in local.enumerated() {
            guard !song.songKey.isEmpty else { continue }
            var seen = Set<Int>()
            if let fingerprint = nonEmpty(song.fingerprint) {
                for serverIndex in byFingerprint[fingerprint] ?? []
                where server[serverIndex].songKey == song.songKey && seen.insert(serverIndex).inserted {
                    edges.append(edge(localIndex, serverIndex, local: song, server: server[serverIndex], kind: .sameAudio))
                }
            }
            for serverIndex in bySongKey[song.songKey] ?? [] where !seen.contains(serverIndex) {
                let candidate = server[serverIndex]
                guard abs(candidate.durationMs - song.durationMs) <= durationToleranceMs else { continue }
                if candidate.albumKey == song.albumKey {
                    edges.append(edge(localIndex, serverIndex, local: song, server: candidate, kind: .sameAlbum))
                } else if song.track > 0, candidate.track == song.track,
                          abs(candidate.durationMs - song.durationMs) <= otherAlbumToleranceMs {
                    edges.append(edge(localIndex, serverIndex, local: song, server: candidate, kind: .sameTrack))
                }
            }
        }
        return edges
    }

    private static func edge(_ localIndex: Int, _ serverIndex: Int, local: Song, server: Song, kind: Kind) -> Edge {
        Edge(
            local: localIndex,
            server: serverIndex,
            kind: kind,
            sameTrack: local.track > 0 && local.track == server.track,
            gapMs: abs(local.durationMs - server.durationMs)
        )
    }

    private static func isPreferred(_ a: Edge, over b: Edge, local: [Song], server: [Song]) -> Bool {
        if a.kind != b.kind { return a.kind.rawValue < b.kind.rawValue }
        if a.sameTrack != b.sameTrack { return a.sameTrack }
        let aLocal = local[a.local], bLocal = local[b.local]
        if aLocal.rank != bLocal.rank { return aLocal.rank > bLocal.rank }
        if a.gapMs != b.gapMs { return a.gapMs < b.gapMs }
        if aLocal.path != bLocal.path { return aLocal.path < bLocal.path }
        return server[a.server].path < server[b.server].path
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }
}
