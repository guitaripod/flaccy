#if DEBUG && !LEGACY_MAC_HANDOFF
import AppIntents
import Foundation
import MidgarCore

/// Runs every Siri and Shortcuts action the way the system runs it, against the library on the device, right at
/// launch, so the first one also proves the database read an intent does when nothing has loaded the library yet.
/// Love This Song is left out: it would queue a love for Last.fm. Launch with `--exercise-intents` and read
/// `IntentsExercise PASS`/`FAIL` lines and `INTENTS EXERCISE PASSED` or `FAILED` in the app log. Music plays for a
/// few seconds per step and is paused at the end.
enum IntentsExercise {

    static let launchArgument = "--exercise-intents"

    private static var failures = 0
    private static var player: AudioPlaying { AudioPlayer.shared }

    static func runIfRequested() {
        guard CommandLine.arguments.contains(launchArgument) else { return }
        Task { await run() }
    }

    private static func run() async {
        await check("Shuffle My Music fills the queue from the library and plays") {
            _ = try await ShuffleLibraryIntent().perform()
            let playing = await waitUntilPlaying()
            return playing && player.queue.count == CleanLibrarySetting.uniquePool(Library.shared.allTracks).count
        }
        await exerciseMixes()
        await exerciseAlbum()
        await exerciseArtist()
        await exercisePlaylist()
        await check("Start Station with no artist starts a station from the song playing") {
            _ = try await StartStationIntent().perform()
            let station = await waitUntil { player.playbackContext.kind == .radio }
            let playing = await waitUntilPlaying()
            return station && playing
        }
        await exerciseSleepTimer()
        await check("Get Current Song answers while a song plays") {
            _ = try await GetCurrentSongIntent().perform()
            return player.currentTrack != nil
        }
        await check("Resume Listening plays the paused queue again") {
            if player.isPlaying { player.togglePlayPause() }
            guard await waitUntil({ !player.isPlaying }) else { return false }
            _ = try await ResumeListeningIntent().perform()
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
                    _ = try await PlayMixIntent(mix: mix).perform()
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
            _ = try await intent.perform()
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
            _ = try await intent.perform()
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
            _ = try await PlayPlaylistIntent(playlist: first).perform()
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
