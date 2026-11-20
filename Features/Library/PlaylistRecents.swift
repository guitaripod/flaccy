import FlaccyCore
import Foundation

/// The playlists last added to on this device, so every Add to Playlist menu
/// offers them first, in the order they were used.
nonisolated enum PlaylistRecents {

    private static let key = "flaccy.playlistWriter.recent"
    private static let limit = 3

    static func noteUsed(_ id: Int64) {
        var recent = UserDefaults.standard.array(forKey: key) as? [Int64] ?? []
        recent.removeAll { $0 == id }
        recent.insert(id, at: 0)
        UserDefaults.standard.set(Array(recent.prefix(limit)), forKey: key)
    }

    /// The playlists last added to first, then the rest as they came.
    static func ordered(_ playlists: [PlaylistRecord]) -> [PlaylistRecord] {
        let recent = UserDefaults.standard.array(forKey: key) as? [Int64] ?? []
        let rank = Dictionary(recent.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        return playlists.enumerated().sorted { left, right in
            let a = left.element.id.flatMap { rank[$0] } ?? Int.max
            let b = right.element.id.flatMap { rank[$0] } ?? Int.max
            return a != b ? a < b : left.offset < right.offset
        }.map(\.element)
    }

    /// The playlists that already hold every one of the songs at `paths`,
    /// for the check beside them in Add to Playlist. A long selection is not
    /// asked about.
    static func holdingAll(_ paths: [String]) -> Set<Int64> {
        guard !paths.isEmpty, paths.count <= 100 else { return [] }
        var holding: Set<Int64>?
        for path in Set(paths) {
            let found = (try? DatabaseManager.shared.playlistIDs(containingTrack: path)) ?? []
            holding = holding.map { $0.intersection(found) } ?? found
            if holding?.isEmpty == true { return [] }
        }
        return holding ?? []
    }
}
