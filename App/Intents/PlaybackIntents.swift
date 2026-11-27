#if !LEGACY_MAC_HANDOFF
import AppIntents
import Foundation

/// Plays one of Home's mixes. Library Radio starts the same station Home's button starts; the others are rebuilt from
/// the play history exactly as Home builds them, and one the history cannot fill yet is reported, never left silent.
struct PlayMixIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play a Mix"
    static let description = IntentDescription("Plays one of the mixes Flaccy builds from your own listening.")

    @Parameter(title: "Mix")
    var mix: FlaccyMix

    @Parameter(title: "Shuffle", default: false)
    var shuffle: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$mix)") {
            \.$shuffle
        }
    }

    init() {}

    init(mix: FlaccyMix) {
        self.mix = mix
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentLibrary.note("Play a Mix \(mix.rawValue)")
        let pool = try await IntentLibrary.requireMusic()
        if mix == .libraryRadio {
            IntentLibrary.player.playLibraryRadio()
            return .result()
        }
        let mixes = await Task.detached {
            SuggestedPlaylistService.build(pool: CleanLibrarySetting.uniquePool(pool))
        }.value
        guard let built = mixes.first(where: { $0.id == mix.rawValue }) else { throw IntentLibrary.fail(.mixNotReady) }
        let context = PlaybackContext(kind: .mix, id: built.id, title: built.title, subtitle: built.subtitle)
        try IntentLibrary.play(built.tracks, context: context, shuffled: shuffle)
        return .result()
    }
}

/// Shuffles the whole library, the way Home's Shuffle button does.
struct ShuffleLibraryIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Shuffle My Music"
    static let description = IntentDescription("Shuffles every song in your Flaccy library.")

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentLibrary.note("Shuffle My Music")
        let pool = try await IntentLibrary.requireMusic()
        let shuffled = await IntentLibrary.offMain { CleanLibrarySetting.uniquePool(pool).shuffled() }
        try IntentLibrary.play(shuffled, context: nil, shuffled: false)
        return .result()
    }
}

/// Picks the queue up where it stopped, putting back the one a previous launch saved when nothing is loaded.
struct ResumeListeningIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Resume Listening"
    static let description = IntentDescription("Picks up your queue where you left it.")

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentLibrary.note("Resume Listening")
        try IntentLibrary.requireListening()
        await IntentLibrary.restoreSavedQueue()
        let player = IntentLibrary.player
        guard !player.queue.isEmpty else { throw IntentLibrary.fail(.nothingToResume) }
        if !player.isPlaying { player.togglePlayPause() }
        return .result()
    }
}

struct PlayAlbumIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Album"
    static let description = IntentDescription("Plays an album from your library.")

    @Parameter(title: "Album")
    var album: AlbumEntity

    @Parameter(title: "Shuffle", default: false)
    var shuffle: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$album)") {
            \.$shuffle
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentLibrary.note("Play Album")
        try IntentLibrary.requireListening()
        guard let found = await IntentLibrary.albums().first(where: { $0.id == album.id }) else {
            throw IntentLibrary.fail(.nothingToPlay)
        }
        let context = PlaybackContext.derived(from: found.tracks.map { .init(album: $0.albumTitle, credit: $0.credit) })
        try IntentLibrary.play(found.tracks, context: context, shuffled: shuffle)
        return .result()
    }
}

/// Plays every song the person owns by one artist, album by album, shuffled unless asked otherwise.
struct PlayArtistIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Artist"
    static let description = IntentDescription("Plays the songs you own by an artist.")

    @Parameter(title: "Artist")
    var artist: ArtistEntity

    @Parameter(title: "Shuffle", default: true)
    var shuffle: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$artist)") {
            \.$shuffle
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentLibrary.note("Play Artist")
        let pool = try await IntentLibrary.requireMusic()
        let id = artist.id
        let tracks = await IntentLibrary.offMain { ArtistEntity.tracks(by: id, in: CleanLibrarySetting.uniquePool(pool)) }
        try IntentLibrary.play(tracks, context: nil, shuffled: shuffle)
        return .result()
    }
}

struct PlayPlaylistIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Playlist"
    static let description = IntentDescription("Plays one of your playlists.")

    @Parameter(title: "Playlist")
    var playlist: PlaylistEntity

    @Parameter(title: "Shuffle", default: false)
    var shuffle: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$playlist)") {
            \.$shuffle
        }
    }

    init() {}

    init(playlist: PlaylistEntity) {
        self.playlist = playlist
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentLibrary.note("Play Playlist")
        let pool = try await IntentLibrary.requireMusic()
        let id = Int64(playlist.id)
        let tracks = await IntentLibrary.offMain { HomeFeedBuilder.playlistTracks(id: id, library: pool, database: .shared) }
        try IntentLibrary.play(tracks, context: playlist.context, shuffled: shuffle)
        return .result()
    }
}

/// Starts an endless station from an artist, or from the song playing when no artist is given.
struct StartStationIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Start Station"
    static let description = IntentDescription("Starts an endless station from an artist, or from the song that is playing.")

    @Parameter(title: "Artist")
    var artist: ArtistEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Start a station from \(\.$artist)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentLibrary.note("Start Station")
        _ = try await IntentLibrary.requireMusic()
        let player = IntentLibrary.player
        if let artist {
            player.startStation(seedArtist: artist.name)
            return .result()
        }
        await IntentLibrary.restoreSavedQueue()
        guard let seed = player.currentTrack else { throw IntentLibrary.fail(.nothingPlaying) }
        player.startStation(seedTrack: seed)
        return .result()
    }
}
#endif
