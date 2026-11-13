import Foundation

/// A song of the library as Make a Playlist sees it: what the model is told about it and what the rules in code
/// need to gather, space and time a playlist. `id` is the track's row in the library database.
public struct MakerSong: Sendable, Equatable, Identifiable {
    public let id: Int
    public let title: String
    public let artist: String
    /// The release credit the song is filed under: the album artist, else the artist.
    public let credit: String
    public let album: String
    public let year: Int?
    public let genre: String?
    public let seconds: Int
    public let loved: Bool
    public let plays: Int
    public let lastPlayed: Date?

    public init(
        id: Int, title: String, artist: String, credit: String, album: String, year: Int? = nil, genre: String? = nil,
        seconds: Int, loved: Bool = false, plays: Int = 0, lastPlayed: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.credit = credit
        self.album = album
        self.year = year
        self.genre = genre
        self.seconds = seconds
        self.loved = loved
        self.plays = plays
        self.lastPlayed = lastPlayed
    }
}

/// One artist of the library as the plan request names it. `id` is a number that stands for the artist in this one
/// request, so the model answers with numbers and can never name an artist the library does not hold.
public struct MakerArtist: Sendable, Equatable, Encodable {
    public let id: Int
    public let name: String
    public let genre: String?
    public let years: String?
    public let songs: Int
    public let loved: Int?
}

/// What flaccy-api's model made of a request: the artists that fit, by their numbers, and the limits the request
/// set. The contract with `POST /v1/playlist/plan`.
public struct PlaylistPlan: Sendable, Equatable, Decodable {
    public let title: String
    public let artists: [Int]
    public let minutes: Int?
    public let count: Int?
    public let fromYear: Int?
    public let toYear: Int?
    public let restDays: Int?
    public let lovedOnly: Bool
    public let note: String

    public init(
        title: String, artists: [Int], minutes: Int? = nil, count: Int? = nil, fromYear: Int? = nil, toYear: Int? = nil,
        restDays: Int? = nil, lovedOnly: Bool = false, note: String = ""
    ) {
        self.title = title
        self.artists = artists
        self.minutes = minutes
        self.count = count
        self.fromYear = fromYear
        self.toYear = toYear
        self.restDays = restDays
        self.lovedOnly = lovedOnly
        self.note = note
    }

    enum CodingKeys: String, CodingKey {
        case title, artists, minutes, count, note
        case fromYear = "from_year"
        case toYear = "to_year"
        case restDays = "rest_days"
        case lovedOnly = "loved_only"
    }
}

/// The body of `POST /v1/playlist/plan`.
public struct PlaylistPlanRequest: Sendable, Equatable, Encodable {
    public let request: String
    public let language: String
    public let artists: [MakerArtist]
}

/// One candidate as `POST /v1/playlist/pick` reads it.
public struct PlaylistPickSong: Sendable, Equatable, Encodable {
    public let id: Int
    public let title: String
    public let artist: String
    public let album: String?
    public let year: Int?
    public let seconds: Int
    public let loved: Bool?
}

/// The body of `POST /v1/playlist/pick`: the candidates to choose from, and for a change the list as it stands.
public struct PlaylistPickRequest: Sendable, Equatable, Encodable {
    public let request: String
    public let language: String
    public let minutes: Int?
    public let count: Int?
    public let change: String?
    public let current: [Int]?
    public let songs: [PlaylistPickSong]
}

/// The library as Make a Playlist reads it: every song, and the artists numbered for one plan request.
public struct PlaylistMakerLibrary: Sendable, Equatable {
    /// The most artists a plan request carries, which flaccy-api enforces too. A library with more sends its
    /// largest, since an artist with a single song changes little about what can be made.
    public static let artistLimit = 1500
    /// The longest name or title sent, which flaccy-api enforces too.
    public static let nameLimit = 150

    public let songs: [MakerSong]
    public let artists: [MakerArtist]
    private let creditByNumber: [Int: String]
    private let songsByCredit: [String: [MakerSong]]

    public init(songs: [MakerSong]) {
        let byCredit = Dictionary(grouping: songs, by: \.credit)
        let largestFirst = byCredit.keys.sorted { one, other in
            let (many, fewer) = (byCredit[one]?.count ?? 0, byCredit[other]?.count ?? 0)
            return many == fewer ? one < other : many > fewer
        }
        var numbered: [Int: String] = [:]
        var lines: [MakerArtist] = []
        for (index, credit) in largestFirst.prefix(Self.artistLimit).enumerated() {
            numbered[index + 1] = credit
            lines.append(Self.line(number: index + 1, credit: credit, songs: byCredit[credit] ?? []))
        }
        self.songs = songs
        songsByCredit = byCredit
        creditByNumber = numbered
        artists = lines
    }

    /// What the model is told about one artist: how much of them the library holds and, where the library knows,
    /// their most common genre and the years their albums span.
    private static func line(number: Int, credit: String, songs: [MakerSong]) -> MakerArtist {
        let years = songs.compactMap(\.year)
        let span = years.min().flatMap { first in years.max().map { last in first == last ? "\(first)" : "\(first)-\(last)" } }
        let genres = Dictionary(grouping: songs.compactMap(\.genre), by: { $0 }).mapValues(\.count)
        let commonest = genres.max { one, other in one.value == other.value ? one.key > other.key : one.value < other.value }?.key
        let loved = songs.count(where: \.loved)
        return MakerArtist(
            id: number, name: String(credit.prefix(nameLimit)), genre: commonest.map { String($0.prefix(nameLimit)) }, years: span,
            songs: songs.count, loved: loved > 0 ? loved : nil)
    }

    public func planRequest(_ request: String, language: String) -> PlaylistPlanRequest {
        PlaylistPlanRequest(request: request, language: language, artists: artists)
    }

    /// The songs of the artists a plan chose, in the plan's order of fit.
    func songs(ofArtists numbers: [Int]) -> [[MakerSong]] {
        numbers.compactMap { creditByNumber[$0] }.compactMap { songsByCredit[$0] }
    }
}

/// The steps of Make a Playlist that code decides, not a model: which songs become candidates, and what the chosen
/// list must satisfy before a person sees it.
public enum PlaylistMaker {
    /// The most candidates a pick request carries, which flaccy-api enforces at 400.
    public static let candidateLimit = 300
    /// A song shorter than this is an interlude or a skit, never a candidate.
    public static let shortestSong = 45
    /// The length assumed for a song when a number of songs has to be guessed from minutes.
    static let usualSongSeconds = 210
    /// How far the list may run from the minutes asked for, either way.
    static let lengthTolerance = 0.15
    /// How many songs a playlist gets when the request named neither a length nor a count.
    public static let usualCount = 20

    /// The candidates for a plan: from each chosen artist, the songs inside the plan's era and rest, the loved and
    /// most played first and then an even spread of the others, so a large catalogue is neither all hits nor
    /// all deep cuts. When a request for loved songs leaves too few to choose from, loved becomes a preference.
    public static func candidates(for plan: PlaylistPlan, in library: PlaylistMakerLibrary, now: Date, limit: Int = candidateLimit) -> [MakerSong] {
        let strict = gather(plan, in: library, now: now, limit: limit, lovedOnly: plan.lovedOnly)
        guard plan.lovedOnly, strict.count < 2 * songsWanted(by: plan) else { return strict }
        return gather(plan, in: library, now: now, limit: limit, lovedOnly: false)
    }

    private static func gather(_ plan: PlaylistPlan, in library: PlaylistMakerLibrary, now: Date, limit: Int, lovedOnly: Bool) -> [MakerSong] {
        let catalogues = library.songs(ofArtists: plan.artists)
        guard !catalogues.isEmpty else { return [] }
        let share = max(4, limit / catalogues.count)
        var pool: [MakerSong] = []
        for catalogue in catalogues {
            let fitting = catalogue.filter { fits($0, plan: plan, now: now, lovedOnly: lovedOnly) }.sorted(by: knownFirst)
            let known = fitting.prefix(share / 2)
            let others = Array(fitting.dropFirst(share / 2))
            let wanted = share - known.count
            let step = max(1, others.count / max(1, wanted))
            pool.append(contentsOf: known)
            pool.append(contentsOf: stride(from: 0, to: others.count, by: step).prefix(wanted).map { others[$0] })
        }
        return Array(pool.prefix(limit))
    }

    private static func fits(_ song: MakerSong, plan: PlaylistPlan, now: Date, lovedOnly: Bool) -> Bool {
        if song.seconds < shortestSong { return false }
        if lovedOnly, !song.loved { return false }
        if let year = song.year {
            if let from = plan.fromYear, year < from { return false }
            if let to = plan.toYear, year > to { return false }
        }
        if let rest = plan.restDays, let played = song.lastPlayed, now.timeIntervalSince(played) < Double(rest) * 86_400 { return false }
        return true
    }

    /// Loved before unloved, more played before less, then by title so the order never depends on the database's.
    private static func knownFirst(_ one: MakerSong, _ other: MakerSong) -> Bool {
        if one.loved != other.loved { return one.loved }
        if one.plays != other.plays { return one.plays > other.plays }
        return one.title == other.title ? one.id < other.id : one.title < other.title
    }

    /// How many songs the plan asks for: its count, else what its minutes hold, else the usual number.
    static func songsWanted(by plan: PlaylistPlan) -> Int {
        if let count = plan.count, count > 0 { return count }
        if let minutes = plan.minutes, minutes > 0 { return max(1, minutes * 60 / usualSongSeconds) }
        return usualCount
    }

    /// The pick request for a plan's candidates, or for a change to the list a person already has.
    public static func pickRequest(
        _ request: String, language: String, plan: PlaylistPlan, candidates: [MakerSong], change: String? = nil, current: [MakerSong] = []
    ) -> PlaylistPickRequest {
        let limit = PlaylistMakerLibrary.nameLimit
        return PlaylistPickRequest(
            request: request, language: language, minutes: plan.minutes, count: plan.count,
            change: change, current: change == nil ? nil : current.map(\.id),
            songs: candidates.map { song in
                PlaylistPickSong(
                    id: song.id, title: String(song.title.prefix(limit)), artist: String(song.artist.prefix(limit)),
                    album: song.album.isEmpty ? nil : String(song.album.prefix(limit)), year: song.year, seconds: song.seconds,
                    loved: song.loved ? true : nil)
            })
    }

    /// The playlist a person sees: the model's choice with unknown and repeated songs gone, brought to the length
    /// or count the plan asked for, and with no artist three times in a row. A model that chose nothing gets the
    /// candidates in turn by artist instead, so a failure upstream still makes a playlist.
    public static func settle(picked: [Int], candidates: [MakerSong], plan: PlaylistPlan) -> [MakerSong] {
        let byID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<Int>()
        var list = picked.compactMap { byID[$0] }.filter { seen.insert($0.id).inserted }
        let spare = inTurnByArtist(candidates.filter { !seen.contains($0.id) })
        list = toLength(list, spare: spare, plan: plan)
        return spaced(list)
    }

    /// Trims from the end or adds from the spare candidates until the list meets the plan's count, or runs within
    /// the tolerance of its minutes. A request that named neither keeps what was chosen, or the usual number when
    /// nothing was.
    private static func toLength(_ chosen: [MakerSong], spare: [MakerSong], plan: PlaylistPlan) -> [MakerSong] {
        var list = chosen
        var spare = spare[...]
        if let count = plan.count, count > 0 {
            list = Array(list.prefix(count))
            while list.count < count, let next = spare.popFirst() { list.append(next) }
            return list
        }
        if let minutes = plan.minutes, minutes > 0 {
            let asked = Double(minutes * 60)
            while list.count > 1, Double(seconds(of: list)) > asked * (1 + lengthTolerance) { list.removeLast() }
            while Double(seconds(of: list)) < asked * (1 - lengthTolerance), let next = spare.popFirst() {
                if Double(seconds(of: list) + next.seconds) <= asked * (1 + lengthTolerance) { list.append(next) }
            }
            return list
        }
        while list.isEmpty || (chosen.isEmpty && list.count < usualCount), let next = spare.popFirst() { list.append(next) }
        return list
    }

    public static func seconds(of songs: [MakerSong]) -> Int {
        songs.reduce(0) { $0 + $1.seconds }
    }

    /// The songs dealt one artist at a time, so songs added by code never arrive as a block of one artist.
    static func inTurnByArtist(_ songs: [MakerSong]) -> [MakerSong] {
        var order: [String] = []
        var queues: [String: [MakerSong]] = [:]
        for song in songs {
            if queues[song.artist] == nil { order.append(song.artist) }
            queues[song.artist, default: []].append(song)
        }
        var dealt: [MakerSong] = []
        var round = 0
        while dealt.count < songs.count {
            for artist in order {
                if let queue = queues[artist], round < queue.count { dealt.append(queue[round]) }
            }
            round += 1
        }
        return dealt
    }

    /// The list with no artist three times in a row where another order allows it: the third song of a run trades
    /// places with the next song by someone else.
    static func spaced(_ songs: [MakerSong]) -> [MakerSong] {
        var list = songs
        guard list.count > 2 else { return list }
        for index in 2..<list.count where list[index].artist == list[index - 1].artist && list[index].artist == list[index - 2].artist {
            if let other = list[(index + 1)...].firstIndex(where: { $0.artist != list[index].artist }) {
                list.swapAt(index, other)
            }
        }
        return list
    }
}
