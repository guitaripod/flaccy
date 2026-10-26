import FlaccyCore
import Foundation

/// The entities a pull or a push made it necessary to recompute, by fold key.
struct SyncDirty: Sendable, Equatable {
    var playlists: Set<String> = []
    var loves: Set<String> = []
    var scalars: Set<String> = []

    var isEmpty: Bool { playlists.isEmpty && loves.isEmpty && scalars.isEmpty }

    mutating func add(foldKey key: String) {
        guard let separator = key.firstIndex(of: ":") else { return }
        let id = String(key[key.index(after: separator)...])
        switch key[..<separator] {
        case "playlist": playlists.insert(id)
        case "love": loves.insert(id)
        case "scalar": scalars.insert(id)
        default: break
        }
    }

    mutating func merge(_ other: SyncDirty) {
        playlists.formUnion(other.playlists)
        loves.formUnion(other.loves)
        scalars.formUnion(other.scalars)
    }
}

/// A cover image the server names that this device does not have yet.
public struct ServerCoverNeed: Sendable, Equatable, Hashable {
    public var playlistSyncID: String
    public var hash: String
}

/// What changed in the app tables, so the screens repaint only that.
public struct ServerSyncChanges: Sendable, Equatable {
    public var playlists = false
    public var loves = false
    public var lyricsOffsets = false
    public var listens = 0
    public var scalarKeys: Set<String> = []

    public init() {}

    public var isEmpty: Bool {
        !playlists && !loves && !lyricsOffsets && listens == 0 && scalarKeys.isEmpty
    }

    mutating func merge(_ other: ServerSyncChanges) {
        playlists = playlists || other.playlists
        loves = loves || other.loves
        lyricsOffsets = lyricsOffsets || other.lyricsOffsets
        listens += other.listens
        scalarKeys.formUnion(other.scalarKeys)
    }
}

/// A scalar whose visible value was recomputed; nil means it is cleared.
struct ServerScalarChange: Sendable, Equatable {
    var key: String
    var value: ServerJSON?
}

/// The result of recomputing dirty entities into the app tables.
struct MaterializeOutcome: Sendable {
    var changes = ServerSyncChanges()
    var scalars: [ServerScalarChange] = []
    var covers: [ServerCoverNeed] = []

    mutating func merge(_ other: MaterializeOutcome) {
        changes.merge(other.changes)
        scalars.append(contentsOf: other.scalars)
        covers.append(contentsOf: other.covers)
    }
}
