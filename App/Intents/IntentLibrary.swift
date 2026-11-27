#if !LEGACY_MAC_HANDOFF
import Foundation
import MidgarCore

/// What the intents need when Siri, Shortcuts or the Action button wakes Flaccy with no window open: the indexed
/// library read back from the database, the saved queue put back the way opening the app does, and the trial
/// asked first, so an ended trial gets a plain answer instead of a paywall that waits for the next launch.
enum IntentLibrary {

    static var player: AudioPlaying { AudioPlayer.shared }

    static func tracks() async -> [Track] {
        await loadIfNeeded()
        return Library.shared.allTracks
    }

    static func albums() async -> [Album] {
        await loadIfNeeded()
        return Library.shared.albums
    }

    static func requireListening() throws {
        guard PurchaseManager.shared.allowsPlayback else { throw fail(.trialEnded) }
    }

    static func requireMusic() async throws -> [Track] {
        try requireListening()
        let pool = await tracks()
        guard !pool.isEmpty else { throw fail(.emptyLibrary) }
        return pool
    }

    /// Runs library-sized work (deduplicating, filtering or sorting tens of thousands of songs) off the main thread,
    /// so an action run while Flaccy is on screen never costs a frame.
    nonisolated static func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await Task.detached(priority: .userInitiated) { work() }.value
    }

    /// Names the action in the app log, so a support log shows what Siri or a shortcut asked for.
    static func note(_ action: String) {
        MidgarLog.info("Intent: \(action)", category: .playback)
    }

    /// Logs why an action stopped before handing the reason to Siri.
    static func fail(_ error: FlaccyIntentError) -> FlaccyIntentError {
        MidgarLog.notice("Intent stopped: \(error)", category: .playback)
        return error
    }

    static func play(_ tracks: [Track], context: PlaybackContext?, shuffled: Bool) throws {
        guard !tracks.isEmpty else { throw fail(.nothingToPlay) }
        MidgarLog.info("Intent plays \(tracks.count) songs (\(context?.key ?? "no context"))", category: .playback)
        player.play(shuffled ? tracks.shuffled() : tracks, startingAt: 0, context: context)
    }

    /// Puts back the queue an earlier launch saved and waits up to five seconds for it. The engine only announces
    /// the end with a notification, so the wait reads its flag instead of holding an observer across the await.
    static func restoreSavedQueue() async {
        guard player.queue.isEmpty else { return }
        player.restoreQueueState()
        var checks = 0
        while player.isRestoringQueue, checks < 100 {
            checks += 1
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Reads the library the last scan indexed when nothing has asked for it yet, as on a launch Siri started. When
    /// the library screen is already loading it (Siri woke the app with its window), that load is awaited instead of
    /// read a second time. A database read only: the folder scan still waits for the library screen.
    private static func loadIfNeeded() async {
        let library = Library.shared
        guard library.allTracks.isEmpty else { return }
        if library.isLoading {
            var checks = 0
            while library.isLoading, library.allTracks.isEmpty, checks < 400 {
                checks += 1
                try? await Task.sleep(for: .milliseconds(25))
            }
            guard library.allTracks.isEmpty else { return }
        }
        await library.reloadFromDatabase()
    }
}

/// Why an intent could not do what it was asked, in words Siri can say.
nonisolated enum FlaccyIntentError: Error, CustomLocalizedStringResourceConvertible {
    case trialEnded
    case emptyLibrary
    case nothingToPlay
    case nothingToResume
    case nothingPlaying
    case mixNotReady

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .trialEnded:
            "Your Flaccy trial has ended. Open Flaccy to keep listening."
        case .emptyLibrary:
            "Your Flaccy library is empty. Open Flaccy to add music."
        case .nothingToPlay:
            "Flaccy found no songs to play there."
        case .nothingToResume:
            "There's nothing to resume yet. Play something in Flaccy first."
        case .nothingPlaying:
            "Nothing is playing in Flaccy."
        case .mixNotReady:
            "That mix isn't ready yet. Flaccy builds it from what you play, so listen for a while first."
        }
    }
}
#endif
