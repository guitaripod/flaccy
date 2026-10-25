import FlaccyCore
import Foundation

/// Where a library list narrows to: the songs stored on this device, or the songs of one server.
/// No source chosen shows every song.
nonisolated enum LibrarySource: Hashable, Sendable {
    case local
    case server(String)

    static let localID = "local"
    static let iosStorageKey = "librarySource"
    static let macStorageKey = "flaccy.mac.songsSource"

    init(id: String) {
        self = id == Self.localID ? .local : .server(id)
    }

    var id: String {
        switch self {
        case .local: Self.localID
        case .server(let serverID): serverID
        }
    }

    static func persisted(key: String) -> LibrarySource? {
        guard let id = UserDefaults.standard.string(forKey: key), !id.isEmpty else { return nil }
        return LibrarySource(id: id)
    }

    static func persist(_ source: LibrarySource?, key: String) {
        UserDefaults.standard.set(source?.id, forKey: key)
    }

    /// Whether a song stored at `path` belongs to this source.
    func admits(path: String) -> Bool {
        guard let song = RemoteTrackPath(path: path) else { return self == .local }
        return self == .server(song.serverID)
    }

    func admits(_ track: Track) -> Bool {
        guard let song = track.remoteSong else { return self == .local }
        return self == .server(song.serverID)
    }

    static var localTitle: String {
        #if os(macOS)
        String(localized: "On This Mac")
        #else
        String(localized: "On This iPhone")
        #endif
    }

    static let localIcon = "internaldrive"
    static let serverIcon = "server.rack"
}

/// One chip of the source row: the source and the words on it.
nonisolated struct LibrarySourceChoice: Hashable, Sendable {
    let source: LibrarySource
    let title: String

    var icon: String { source == .local ? LibrarySource.localIcon : LibrarySource.serverIcon }

    /// The local source followed by one per server; none at all while no server is added.
    static func choices(servers: [(id: String, name: String)]) -> [LibrarySourceChoice] {
        guard !servers.isEmpty else { return [] }
        return [LibrarySourceChoice(source: .local, title: LibrarySource.localTitle)]
            + servers.map { LibrarySourceChoice(source: .server($0.id), title: $0.name) }
    }
}
