#if !LEGACY_MAC_HANDOFF
import AppIntents
import Foundation

/// An album as Shortcuts and Siri name it, keyed by the `title|artist` id Home and Search already key albums by.
nonisolated struct AlbumEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Album")
    static let defaultQuery = AlbumEntityQuery()

    let id: String
    let title: String
    let artist: String

    init(album: Album) {
        id = album.id
        title = album.title
        artist = album.artist
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(artist)", image: .init(systemName: "square.stack"))
    }
}

nonisolated struct AlbumEntityQuery: EntityStringQuery {
    static let limit = 50

    func entities(for identifiers: [String]) async throws -> [AlbumEntity] {
        let byID = Dictionary(await Self.all().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return identifiers.compactMap { byID[$0] }
    }

    func entities(matching string: String) async throws -> [AlbumEntity] {
        let found = await Self.all().filter {
            $0.title.localizedStandardContains(string) || $0.artist.localizedStandardContains(string)
        }
        return Array(found.prefix(Self.limit))
    }

    func suggestedEntities() async throws -> [AlbumEntity] {
        Array(await Self.all().prefix(Self.limit))
    }

    private static func all() async -> [AlbumEntity] {
        let albums = await IntentLibrary.albums()
        return await IntentLibrary.offMain {
            albums.map(AlbumEntity.init(album:)).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
    }
}

/// An artist as the credits on the person's own songs spell it, keyed by the folded name Home's stations use.
nonisolated struct ArtistEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Artist")
    static let defaultQuery = ArtistEntityQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: .init(systemName: "music.mic"))
    }

    /// The songs credited to the artist, folding each distinct spelling once rather than twice per song.
    static func tracks(by id: String, in pool: [Track]) -> [Track] {
        var folded: [String: String] = [:]
        func key(_ name: String) -> String {
            if let known = folded[name] { return known }
            let key = HomeKeys.fold(name)
            folded[name] = key
            return key
        }
        return pool.filter { key($0.artist) == id || key($0.credit) == id }
    }

    /// Every artist credited on a song, each once, under the spelling its first song uses.
    static func all(in pool: [Track]) -> [ArtistEntity] {
        var spellings = Set<String>()
        var seen = Set<String>()
        var artists: [ArtistEntity] = []
        for track in pool where spellings.insert(track.credit).inserted {
            let key = HomeKeys.fold(track.credit)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            artists.append(ArtistEntity(id: key, name: track.credit))
        }
        return artists.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

nonisolated struct ArtistEntityQuery: EntityStringQuery {
    static let limit = 50

    func entities(for identifiers: [String]) async throws -> [ArtistEntity] {
        let byID = Dictionary(await Self.all().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return identifiers.compactMap { byID[$0] }
    }

    func entities(matching string: String) async throws -> [ArtistEntity] {
        Array(await Self.all().filter { $0.name.localizedStandardContains(string) }.prefix(Self.limit))
    }

    func suggestedEntities() async throws -> [ArtistEntity] {
        Array(await Self.all().prefix(Self.limit))
    }

    private static func all() async -> [ArtistEntity] {
        let pool = await IntentLibrary.tracks()
        return await IntentLibrary.offMain { ArtistEntity.all(in: pool) }
    }
}

/// One of the person's playlists, keyed by its database row.
nonisolated struct PlaylistEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Playlist")
    static let defaultQuery = PlaylistEntityQuery()

    let id: Int
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: .init(systemName: "music.note.list"))
    }

    var context: PlaybackContext {
        PlaybackContext(kind: .playlist, id: String(id), title: name, subtitle: "")
    }
}

nonisolated struct PlaylistEntityQuery: EntityStringQuery {

    func entities(for identifiers: [Int]) async throws -> [PlaylistEntity] {
        let byID = Dictionary(Self.all().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return identifiers.compactMap { byID[$0] }
    }

    func entities(matching string: String) async throws -> [PlaylistEntity] {
        Self.all().filter { $0.name.localizedStandardContains(string) }
    }

    func suggestedEntities() async throws -> [PlaylistEntity] {
        Self.all()
    }

    static func all() -> [PlaylistEntity] {
        let records = (try? DatabaseManager.shared.fetchAllPlaylists()) ?? []
        return records.compactMap { record in
            record.id.map { PlaylistEntity(id: Int($0), name: record.name) }
        }
    }
}

/// The mixes Home builds from the person's own listening, by the ids Home gives them.
nonisolated enum FlaccyMix: String, AppEnum, CaseIterable {
    case heavyRotation = "heavy-rotation"
    case crateDig = "crate-dig"
    case onRepeat = "on-repeat"
    case rediscover
    case tonightsSpin = "tonights-spin"
    case libraryRadio = "library-radio"

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Mix")

    static let caseDisplayRepresentations: [FlaccyMix: DisplayRepresentation] = [
        .heavyRotation: DisplayRepresentation(title: "Heavy Rotation", image: .init(systemName: "flame.fill")),
        .crateDig: DisplayRepresentation(title: "Crate Dig", image: .init(systemName: "opticaldisc.fill")),
        .onRepeat: DisplayRepresentation(title: "On Repeat", image: .init(systemName: "repeat")),
        .rediscover: DisplayRepresentation(title: "Rediscover", image: .init(systemName: "clock.arrow.circlepath")),
        .tonightsSpin: DisplayRepresentation(title: "Tonight's Spin", image: .init(systemName: "record.circle")),
        .libraryRadio: DisplayRepresentation(title: "Library Radio", image: .init(systemName: "dot.radiowaves.left.and.right")),
    ]
}

/// The sleep timer lengths the Now Playing menu offers, plus turning it off.
nonisolated enum SleepTimerLength: String, AppEnum {
    case fifteen
    case thirty
    case fortyFive
    case sixty
    case endOfTrack
    case off

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Sleep Timer")

    static let caseDisplayRepresentations: [SleepTimerLength: DisplayRepresentation] = [
        .fifteen: "15 minutes",
        .thirty: "30 minutes",
        .fortyFive: "45 minutes",
        .sixty: "60 minutes",
        .endOfTrack: "End of Track",
        .off: "Off",
    ]

    var minutes: Int? {
        switch self {
        case .fifteen: 15
        case .thirty: 30
        case .fortyFive: 45
        case .sixty: 60
        case .endOfTrack, .off: nil
        }
    }
}
#endif
