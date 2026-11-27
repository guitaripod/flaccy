#if !LEGACY_MAC_HANDOFF
import AppIntents
import Foundation

/// Sets the same sleep timer the Now Playing menu sets, so a Sleep Focus automation can wind the music down.
struct SetSleepTimerIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Sleep Timer"
    static let description = IntentDescription("Stops the music after a while, or at the end of the song.")

    @Parameter(title: "Sleep Timer")
    var length: SleepTimerLength

    static var parameterSummary: some ParameterSummary {
        Summary("Set the sleep timer to \(\.$length)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let player = IntentLibrary.player
        switch length {
        case .off:
            player.cancelSleepTimer()
            return .result(dialog: "The sleep timer is off.")
        case .endOfTrack:
            player.setSleepTimerEndOfTrack()
            return .result(dialog: "Flaccy stops at the end of this song.")
        case .fifteen, .thirty, .fortyFive, .sixty:
            let minutes = length.minutes ?? 0
            player.setSleepTimer(minutes: minutes)
            return .result(dialog: "Flaccy stops in \(minutes) minutes.")
        }
    }
}

/// Loves the song that is playing, locally and on Last.fm when signed in; a song already loved stays loved.
struct LoveCurrentSongIntent: AppIntent {
    static let title: LocalizedStringResource = "Love This Song"
    static let description = IntentDescription("Loves the song that is playing, on Last.fm too when you're signed in.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let track = IntentLibrary.player.currentTrack else { throw FlaccyIntentError.nothingPlaying }
        let loves = LovedTracksService.shared
        guard !loves.isLoved(track: track) else {
            return .result(dialog: "\(track.title) is already loved.")
        }
        await loves.toggleLove(track: track)
        return .result(dialog: "Loved \(track.title).")
    }
}

/// Says what is playing and hands a shortcut the song and artist as text.
struct GetCurrentSongIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Current Song"
    static let description = IntentDescription("Tells you what Flaccy is playing.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let player = IntentLibrary.player
        guard let track = player.currentTrack else { throw FlaccyIntentError.nothingPlaying }
        let line = track.artist.isEmpty ? track.title : "\(track.title) – \(track.artist)"
        guard !track.artist.isEmpty else {
            return .result(value: line, dialog: "\(track.title)")
        }
        let dialog: IntentDialog = player.isPlaying
            ? "Playing \(track.title) by \(track.artist)."
            : "Paused on \(track.title) by \(track.artist)."
        return .result(value: line, dialog: dialog)
    }
}
#endif
