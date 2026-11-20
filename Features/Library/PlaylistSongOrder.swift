import FlaccyCore
import Foundation

/// How a playlist page lists its songs. Playlist Order is the person's own
/// order and the only one a drag can change; the others are views of it that
/// also decide what Play plays. Each playlist remembers its own on this
/// device.
nonisolated enum PlaylistSongOrder: String, CaseIterable, Sendable {
    case playlist
    case title
    case artist
    case album
    case recentlyAdded
    case duration

    var title: String {
        switch self {
        case .playlist: String(localized: "Playlist Order")
        case .title: String(localized: "Title")
        case .artist: String(localized: "Artist")
        case .album: String(localized: "Album")
        case .recentlyAdded: String(localized: "Recently Added")
        case .duration: String(localized: "Duration")
        }
    }

    var systemImage: String {
        switch self {
        case .playlist: "list.number"
        case .title: "textformat"
        case .artist: "music.microphone"
        case .album: "square.stack"
        case .recentlyAdded: "clock"
        case .duration: "timer"
        }
    }

    private static func key(_ playlistId: Int64) -> String { "flaccy.playlistOrder.\(playlistId)" }

    static func saved(for playlistId: Int64) -> PlaylistSongOrder {
        UserDefaults.standard.string(forKey: key(playlistId)).flatMap(PlaylistSongOrder.init(rawValue:)) ?? .playlist
    }

    static func save(_ order: PlaylistSongOrder, for playlistId: Int64) {
        if order == .playlist {
            UserDefaults.standard.removeObject(forKey: key(playlistId))
        } else {
            UserDefaults.standard.set(order.rawValue, forKey: key(playlistId))
        }
    }

    /// `rows` in this order. Each row is the entry's id, which rises as songs
    /// are added, with its song when the library has it; songs the library
    /// lost sort last.
    func sorted<Row>(_ rows: [Row], entryId: (Row) -> Int64, track: (Row) -> Track?) -> [Row] {
        guard self != .playlist else { return rows }
        return rows.enumerated().sorted { left, right in
            let a = left.element
            let b = right.element
            if self == .recentlyAdded { return entryId(a) > entryId(b) }
            guard let first = track(a), let second = track(b) else {
                return track(a) != nil || (track(b) == nil && left.offset < right.offset)
            }
            let order = compare(first, second)
            return order == .orderedSame ? left.offset < right.offset : order == .orderedAscending
        }.map(\.element)
    }

    private func compare(_ a: Track, _ b: Track) -> ComparisonResult {
        switch self {
        case .playlist, .recentlyAdded: .orderedSame
        case .title: a.title.localizedStandardCompare(b.title)
        case .artist: chained(a.artist.localizedStandardCompare(b.artist), a.title.localizedStandardCompare(b.title))
        case .album:
            chained(
                a.albumTitle.localizedStandardCompare(b.albumTitle),
                a.trackNumber == b.trackNumber ? .orderedSame : (a.trackNumber < b.trackNumber ? .orderedAscending : .orderedDescending)
            )
        case .duration: a.duration == b.duration ? .orderedSame : (a.duration < b.duration ? .orderedAscending : .orderedDescending)
        }
    }

    private func chained(_ first: ComparisonResult, _ then: ComparisonResult) -> ComparisonResult {
        first == .orderedSame ? then : first
    }
}
