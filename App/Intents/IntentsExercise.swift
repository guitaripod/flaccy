#if DEBUG && !LEGACY_MAC_HANDOFF
import AppIntents
import Foundation
import MidgarCore

/// Runs every Siri and Shortcuts action the way the system runs it, against the library on the device, right at
/// launch, so the first one also proves the database read an intent does when nothing has loaded the library yet.
/// Love This Song is left out: it would queue a love for Last.fm. Launch with `--exercise-intents` and read
/// `IntentsExercise PASS`/`FAIL` lines and `INTENTS EXERCISE PASSED` or `FAILED` in the app log. Music plays for a
/// few seconds per step and is paused at the end. Each action's own time is logged as `IntentsExercise TIME`, and the
/// library-sized work behind them is timed again over fifty thousand songs built from the device's own.
enum IntentsExercise {

    static let launchArgument = "--exercise-intents"

    private static var failures = 0
    private static var player: AudioPlaying { AudioPlayer.shared }

    static func runIfRequested() {
        guard CommandLine.arguments.contains(launchArgument) else { return }
        Task { await run() }
    }

    private static func run() async {
        await check("Shuffle My Music fills the queue from the library, plays, and keeps the queue for Resume") {
            try await timed("Shuffle My Music") { _ = try await ShuffleLibraryIntent().perform() }
            let playing = await waitUntilPlaying()
            let kept = UserDefaults.standard.stringArray(forKey: "flaccy.queue.paths")?.count == player.queue.count
            return playing && kept && player.queue.count == CleanLibrarySetting.uniquePool(Library.shared.allTracks).count
        }
        await exerciseMixes()
        await exerciseAlbum()
        await exerciseArtist()
        await exercisePlaylist()
        await check("Start Station with no artist starts a station from the song playing") {
            try await timed("Start Station") { _ = try await StartStationIntent().perform() }
            let station = await waitUntil { player.playbackContext.kind == .radio }
            let playing = await waitUntilPlaying()
            return station && playing
        }
        await exerciseSleepTimer()
        await exerciseScale()
        await check("Get Current Song answers while a song plays") {
            try await timed("Get Current Song") { _ = try await GetCurrentSongIntent().perform() }
            return player.currentTrack != nil
        }
        await check("Resume Listening plays the paused queue again") {
            if player.isPlaying { player.togglePlayPause() }
            guard await waitUntil({ !player.isPlaying }) else { return false }
            try await timed("Resume Listening") { _ = try await ResumeListeningIntent().perform() }
            return await waitUntilPlaying()
        }
        if player.isPlaying { player.togglePlayPause() }
        MidgarLog.info(failures == 0 ? "INTENTS EXERCISE PASSED" : "INTENTS EXERCISE FAILED (\(failures))", category: .playback)
    }

    private static func exerciseMixes() async {
        let pool = CleanLibrarySetting.uniquePool(await IntentLibrary.tracks())
        let built = Set(SuggestedPlaylistService.build(pool: pool).map(\.id))
        for mix in FlaccyMix.allCases {
            if mix == .libraryRadio || built.contains(mix.rawValue) {
                await check("Play a Mix starts \(mix.rawValue)") {
                    try await timed("Play a Mix \(mix.rawValue)") { _ = try await PlayMixIntent(mix: mix).perform() }
                    let expected = mix == .libraryRadio ? PlaybackContext.Kind.radio : .mix
                    let started = await waitUntil { player.playbackContext.kind == expected }
                    let playing = await waitUntilPlaying()
                    return started && playing
                }
            } else {
                await check("Play a Mix says \(mix.rawValue) is not ready on a library that cannot build it") {
                    do {
                        _ = try await PlayMixIntent(mix: mix).perform()
                        return false
                    } catch FlaccyIntentError.mixNotReady {
                        return true
                    }
                }
            }
        }
    }

    private static func exerciseAlbum() async {
        await check("Play Album finds an album by name and plays all of it") {
            guard let first = try await AlbumEntityQuery().suggestedEntities().first else { return false }
            let found = try await AlbumEntityQuery().entities(matching: String(first.title.prefix(4)))
            let resolved = try await AlbumEntityQuery().entities(for: [first.id])
            guard found.contains(where: { $0.id == first.id }), resolved.first?.id == first.id else { return false }
            let expected = Library.shared.albums.first { $0.id == first.id }?.tracks.count ?? -1
            var intent = PlayAlbumIntent()
            intent.album = first
            try await timed("Play Album") { _ = try await intent.perform() }
            let playing = await waitUntilPlaying()
            return playing && player.queue.count == expected && player.playbackContext.kind == .album
        }
    }

    private static func exerciseArtist() async {
        await check("Play Artist finds an artist by name and plays only their songs") {
            guard let first = try await ArtistEntityQuery().suggestedEntities().first else { return false }
            let found = try await ArtistEntityQuery().entities(matching: String(first.name.prefix(3)))
            guard found.contains(where: { $0.id == first.id }) else { return false }
            var intent = PlayArtistIntent()
            intent.artist = first
            try await timed("Play Artist") { _ = try await intent.perform() }
            let theirs = Set(ArtistEntity.tracks(by: first.id, in: Library.shared.allTracks).map(\.fileURL))
            let playing = await waitUntilPlaying()
            return playing && !player.queue.isEmpty && player.queue.allSatisfy { theirs.contains($0.fileURL) }
        }
    }

    /// Plays the first playlist, or a three-song one made for the check and deleted after it on a device with none.
    private static func exercisePlaylist() async {
        let made = PlaylistEntityQuery.all().isEmpty ? makeScratchPlaylist() : nil
        defer { if let made { try? DatabaseManager.shared.deletePlaylist(id: made) } }
        guard let first = PlaylistEntityQuery.all().first else {
            report("Play Playlist has a playlist to play", false)
            return
        }
        await check("Play Playlist finds \(first.name) by name and plays it") {
            let found = try await PlaylistEntityQuery().entities(matching: String(first.name.prefix(5)))
            guard found.contains(where: { $0.id == first.id }) else { return false }
            try await timed("Play Playlist") { _ = try await PlayPlaylistIntent(playlist: first).perform() }
            let playing = await waitUntilPlaying()
            return playing && player.playbackContext == first.context
        }
    }

    private static func makeScratchPlaylist() -> Int64? {
        let paths = Library.shared.allTracks.prefix(3).map { LibraryPaths.relativePath(of: $0.fileURL) }
        return try? DatabaseManager.shared.createPlaylist(name: "Intents Exercise", trackFileURLs: paths).id
    }

    private static func exerciseSleepTimer() async {
        await check("Set Sleep Timer to 15 minutes sets the player's timer") {
            var intent = SetSleepTimerIntent()
            intent.length = .fifteen
            _ = try await intent.perform()
            return (890...900).contains(player.sleepTimerRemaining ?? 0)
        }
        await check("Set Sleep Timer to the end of the song and then off") {
            var intent = SetSleepTimerIntent()
            intent.length = .endOfTrack
            _ = try await intent.perform()
            guard player.sleepAtEndOfTrack, player.sleepTimerRemaining == nil else { return false }
            intent.length = .off
            _ = try await intent.perform()
            return !player.sleepAtEndOfTrack && player.sleepTimerRemaining == nil
        }
    }

    /// Times what an action costs at fifty thousand songs, so deduplication, artist folding and the playlist lookup all
    /// work at full size.
    private static func exerciseScale() async {
        let real = Library.shared.allTracks
        guard !real.isEmpty else { return }
        await settleBeforeTiming()
        let songs = scaleSongs
        let pool = await IntentLibrary.offMain { scalePool(from: real, count: songs) }
        let playlist = PlaylistEntityQuery.all().first.map { Int64($0.id) }
        let timings = await IntentLibrary.offMain { () -> [(String, Double)] in
            let clock = ContinuousClock()
            var results: [(String, Double)] = []
            var artists: [ArtistEntity] = []
            results.append(("deduplicate and shuffle", milliseconds(clock.measure { _ = CleanLibrarySetting.uniquePool(pool).shuffled() })))
            results.append(("list artists", milliseconds(clock.measure { artists = ArtistEntity.all(in: pool) })))
            let id = artists.first?.id ?? ""
            results.append(("one artist's songs", milliseconds(clock.measure { _ = ArtistEntity.tracks(by: id, in: pool) })))
            if let playlist {
                results.append(("a playlist's songs", milliseconds(clock.measure {
                    _ = HomeFeedBuilder.playlistTracks(id: playlist, library: pool, database: .shared)
                })))
            }
            return results
        }
        for (name, elapsed) in timings {
            report("at \(scaleSongs) songs, \(name) takes \(Int(elapsed)) ms (budget \(Int(scaleBudget)) ms, off the main thread)", elapsed < scaleBudget)
        }
    }

    /// Copies of the device's songs, each a distinct song under its own path, a third under other artist names, on
    /// four thousand albums: a large library of the usual shape, not one song owned fifty thousand times.
    nonisolated private static func scalePool(from real: [Track], count: Int) -> [Track] {
        (0..<count).map { index in
            let song = real[index % real.count]
            return Track(
                fileURL: song.fileURL.deletingLastPathComponent().appendingPathComponent("\(index)-\(song.fileURL.lastPathComponent)"),
                title: "\(song.title) \(index)",
                artist: index % 3 == 0 ? "\(song.artist) \(index % 500)" : song.artist,
                albumTitle: "\(song.albumTitle) \(index % 4000)",
                albumArtist: song.albumArtist,
                trackNumber: song.trackNumber,
                duration: song.duration,
                artwork: nil,
                dbID: nil
            )
        }
    }

    /// Pauses and lets Home finish redrawing, so the timings measure the work and not the cores Home is busy with:
    /// a library of one-second test songs would otherwise rebuild Home every second while the clock runs.
    private static func settleBeforeTiming() async {
        if player.isPlaying { player.togglePlayPause() }
        try? await Task.sleep(for: .seconds(3))
    }

    private static let scaleSongs = 50_000
    private static let scaleBudget: Double = 1_000

    private static func timed(_ name: String, _ body: () async throws -> Void) async throws {
        let elapsed = try await ContinuousClock().measure { try await body() }
        MidgarLog.info("IntentsExercise TIME: \(name) took \(Int(milliseconds(elapsed))) ms", category: .playback)
    }

    nonisolated private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }

    private static func check(_ expectation: String, _ body: () async throws -> Bool) async {
        let passed: Bool
        do {
            passed = try await body()
        } catch {
            MidgarLog.info("IntentsExercise threw: \(error)", category: .playback)
            passed = false
        }
        report(expectation, passed)
    }

    private static func report(_ expectation: String, _ passed: Bool) {
        if !passed { failures += 1 }
        MidgarLog.info("IntentsExercise \(passed ? "PASS" : "FAIL"): \(expectation)", category: .playback)
    }

    private static func waitUntilPlaying() async -> Bool {
        await waitUntil { player.isPlaying && player.currentTrack != nil }
    }

    private static func waitUntil(seconds: Double = 8, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        try? await Task.sleep(for: .seconds(1))
        return condition()
    }
}
#endif
