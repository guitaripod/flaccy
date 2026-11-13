import MidgarCore
#if DEBUG
import FlaccyCore
import FlaccyEngine
import Foundation

/// Makes a playlist from the library on this device through the real flaccy-api, changes it, saves it twice and
/// removes what it saved, logging `MAKE PLAYLIST DRILL PASSED` or `MAKE PLAYLIST DRILL FAILED: <step>`.
/// Launch with `--exercise-make-playlist` over a library (`--seed-screenshots` gives a simulator one);
/// `FLACCY_PLAYLIST_REQUEST` replaces the sentence and `-AppleLanguages "(fi)"` asks in another language.
@MainActor
enum PlaylistMakerExercise {

    static let launchArgument = "--exercise-make-playlist"

    private static let usualRequest = "something calm for a slow morning, about 20 minutes"
    private static let usualMinutes = 20
    private static let change = "swap the first song for a different one and keep the rest"

    static func runIfRequested() {
        guard CommandLine.arguments.contains(launchArgument) else { return }
        Task { await run() }
    }

    private static func run() async {
        guard await libraryArrived() else { return fail("the library never loaded") }
        let service = PlaylistMakerService.shared
        let asked = ProcessInfo.processInfo.environment["FLACCY_PLAYLIST_REQUEST"]
        let request = asked ?? usualRequest
        MidgarLog.info("PlaylistMakerExercise asks in \(LyricsMeaningService.languageName): \(request)", category: .content)

        let started = Date()
        let made = await service.make(request) { step in
            MidgarLog.info("PlaylistMakerExercise step \(step)", category: .content)
        }
        guard case .success(let draft) = made else { return fail("no playlist was made (\(made))") }
        MidgarLog.info(
            "PlaylistMakerExercise made \"\(draft.title)\": \(draft.tracks.count) songs, \(draft.seconds / 60) min, in "
                + "\(String(format: "%.1f", Date().timeIntervalSince(started))) s, note \"\(draft.note)\"",
            category: .content)
        for (place, track) in draft.tracks.enumerated() {
            MidgarLog.info("PlaylistMakerExercise \(place + 1). \(track.artist) - \(track.title)", category: .content)
        }
        if let flaw = flaw(in: draft, minutes: asked == nil ? usualMinutes : nil) { return fail(flaw) }

        let changed = await service.change(draft, to: change) { _ in }
        guard case .success(let second) = changed else { return fail("the playlist was not changed (\(changed))") }
        MidgarLog.info(
            "PlaylistMakerExercise changed: \(second.tracks.count) songs, first now \(second.tracks.first?.title ?? "none"), "
                + "\(Set(second.tracks.map(\.fileURL)).subtracting(draft.tracks.map(\.fileURL)).count) new",
            category: .content)
        if let flaw = flaw(in: second, minutes: nil) { return fail("after the change, \(flaw)") }

        if let flaw = savingFlaw(second, service: service) { return fail(flaw) }
        MidgarLog.info("MAKE PLAYLIST DRILL PASSED", category: .content)
    }

    /// What is wrong with a made playlist as a list, or nil: no song twice, no artist three times in a row, and
    /// the length that was asked for when `minutes` names one.
    private static func flaw(in draft: PlaylistDraft, minutes: Int?) -> String? {
        let tracks = draft.tracks
        guard !tracks.isEmpty else { return "the playlist is empty" }
        guard Set(tracks.map(\.fileURL)).count == tracks.count else { return "a song is in the playlist twice" }
        for start in tracks.indices.dropLast(2) where tracks[start].artist == tracks[start + 1].artist && tracks[start].artist == tracks[start + 2].artist {
            return "\(tracks[start].artist) plays three times in a row"
        }
        guard let minutes else { return nil }
        let wanted = Double(minutes * 60)
        let longest = tracks.map(\.duration).max() ?? 0
        guard abs(Double(draft.seconds) - wanted) <= wanted * PlaylistMaker.lengthTolerance + longest else {
            return "the playlist runs \(draft.seconds / 60) minutes where \(minutes) were asked for"
        }
        return nil
    }

    /// Saves the playlist twice and removes both, returning what went wrong, or nil: each save is an ordinary
    /// playlist holding every song in order, and the second takes a name of its own.
    private static func savingFlaw(_ draft: PlaylistDraft, service: PlaylistMakerService) -> String? {
        let database = DatabaseManager.shared
        do {
            let first = try service.save(draft, path: path(of:))
            let second = try service.save(draft, path: path(of:))
            defer {
                for id in [first.id, second.id].compactMap({ $0 }) { try? database.deletePlaylist(id: id) }
            }
            guard let id = first.id else { return "the saved playlist has no row" }
            let kept = try database.fetchPlaylistTracks(playlistId: id)
            guard kept.count == draft.tracks.count else {
                return "the saved playlist holds \(kept.count) of \(draft.tracks.count) songs"
            }
            guard first.name != second.name else { return "two saved playlists share the name \(first.name)" }
            MidgarLog.info("PlaylistMakerExercise saved as \"\(first.name)\" and \"\(second.name)\", \(kept.count) songs each", category: .content)
            return nil
        } catch {
            return "saving threw \(error.localizedDescription)"
        }
    }

    private static func path(of track: Track) -> String {
        #if os(macOS)
        LibraryPathResolver.relativePath(for: track.fileURL)
        #else
        TrackContextMenu.relativePath(for: track)
        #endif
    }

    /// Waits up to a minute for the library to hold music.
    private static func libraryArrived() async -> Bool {
        for _ in 0..<120 {
            if !Library.shared.albums.isEmpty { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }

    private static func fail(_ step: String) {
        MidgarLog.error("MAKE PLAYLIST DRILL FAILED: \(step)", category: .content)
    }
}
#endif
