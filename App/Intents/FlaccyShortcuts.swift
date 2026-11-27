#if !LEGACY_MAC_HANDOFF
import AppIntents
import Foundation
import GRDB

/// The phrases Siri, Spotlight, the Shortcuts app and the Action button know without any setup. The phrases are
/// localized in `Resources/AppShortcuts.xcstrings`; each keeps `${applicationName}` so Siri can tell the app apart.
struct FlaccyShortcuts: AppShortcutsProvider {
    static let shortcutTileColor: ShortcutTileColor = .orange

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlayMixIntent(),
            phrases: [
                "Play \(\.$mix) in \(.applicationName)",
                "Start \(\.$mix) in \(.applicationName)",
                "Play a mix in \(.applicationName)",
            ],
            shortTitle: "Play a Mix",
            systemImageName: "flame.fill"
        )
        AppShortcut(
            intent: ShuffleLibraryIntent(),
            phrases: [
                "Shuffle my music in \(.applicationName)",
                "Shuffle my library in \(.applicationName)",
                "Shuffle \(.applicationName)",
            ],
            shortTitle: "Shuffle My Music",
            systemImageName: "shuffle"
        )
        AppShortcut(
            intent: ResumeListeningIntent(),
            phrases: [
                "Resume \(.applicationName)",
                "Resume my music in \(.applicationName)",
                "Keep listening in \(.applicationName)",
            ],
            shortTitle: "Resume Listening",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: PlayPlaylistIntent(),
            phrases: [
                "Play my \(\.$playlist) playlist in \(.applicationName)",
                "Play the playlist \(\.$playlist) in \(.applicationName)",
                "Play a playlist in \(.applicationName)",
            ],
            shortTitle: "Play Playlist",
            systemImageName: "music.note.list"
        )
        AppShortcut(
            intent: PlayAlbumIntent(),
            phrases: [
                "Play an album in \(.applicationName)",
            ],
            shortTitle: "Play Album",
            systemImageName: "square.stack"
        )
        AppShortcut(
            intent: PlayArtistIntent(),
            phrases: [
                "Play an artist in \(.applicationName)",
            ],
            shortTitle: "Play Artist",
            systemImageName: "music.mic"
        )
        AppShortcut(
            intent: StartStationIntent(),
            phrases: [
                "Start a station in \(.applicationName)",
                "Start a station from this song in \(.applicationName)",
            ],
            shortTitle: "Start Station",
            systemImageName: "dot.radiowaves.left.and.right"
        )
        AppShortcut(
            intent: SetSleepTimerIntent(),
            phrases: [
                "Set a sleep timer in \(.applicationName)",
                "Start a sleep timer in \(.applicationName)",
            ],
            shortTitle: "Sleep Timer",
            systemImageName: "moon.zzz.fill"
        )
        AppShortcut(
            intent: LoveCurrentSongIntent(),
            phrases: [
                "Love this song in \(.applicationName)",
                "Love the song playing in \(.applicationName)",
            ],
            shortTitle: "Love This Song",
            systemImageName: "heart.fill"
        )
        AppShortcut(
            intent: GetCurrentSongIntent(),
            phrases: [
                "What's playing in \(.applicationName)",
                "What song is this in \(.applicationName)",
            ],
            shortTitle: "Current Song",
            systemImageName: "music.note"
        )
    }
}

/// Keeps the playlist names Siri listens for in step with the playlists on this device, from any client or a sync.
final class ShortcutParameterRefresh {

    static let shared = ShortcutParameterRefresh()

    private var observation: AnyDatabaseCancellable?

    private init() {}

    func start() {
        guard observation == nil else { return }
        observation = DatabaseManager.shared.observePlaylists { _ in
            FlaccyShortcuts.updateAppShortcutParameters()
        }
    }
}
#endif
