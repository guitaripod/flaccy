import FlaccyCore
import Foundation

/// The words of Make a Playlist on iPhone, iPad and Mac.
nonisolated enum PlaylistMakerCopy {

    static var title: String { String(localized: "Make a Playlist") }
    static var menuTitle: String { String(localized: "Make a Playlist…") }
    static var placeholder: String { String(localized: "Rainy Sunday morning, calm, about 40 minutes") }
    static var make: String { String(localized: "Make Playlist") }
    static var play: String { String(localized: "Play") }
    static var save: String { String(localized: "Save") }
    static var saved: String { String(localized: "Saved") }
    static var changeIt: String { String(localized: "Change It") }
    static var change: String { String(localized: "Change") }
    static var cancel: String { String(localized: "Cancel") }
    static var changePlaceholder: String { String(localized: "More upbeat, fewer film scores") }
    static var tryAgain: String { String(localized: "Try Again") }
    static var seePlans: String { String(localized: "See Plans") }

    /// What a person is told before they ask: what is made, and what leaves the device to make it.
    static var explanation: String {
        String(localized: "Say what you want to hear and Flaccy makes a playlist from the music you own. Your words and the names of your artists and songs go to Flaccy's AI to choose them. Nothing else leaves this device.")
    }

    /// Requests a person can tap to see what to ask for.
    static var examples: [String] {
        [
            String(localized: "Something I haven't played in a while"),
            String(localized: "Upbeat, for a 30 minute run"),
            String(localized: "Late night, quiet"),
            String(localized: "My favourites from the 90s"),
        ]
    }

    static func step(_ step: PlaylistMakerStep) -> String {
        switch step {
        case .readingLibrary: return String(localized: "Reading your library…")
        case .planning: return String(localized: "Finding the artists that fit…")
        case .choosing: return String(localized: "Choosing the songs…")
        }
    }

    /// "12 songs · 41 min", the line under a made playlist's name.
    static func summary(songs: Int, seconds: Int) -> String {
        let minutes = max(1, Int((Double(seconds) / 60).rounded()))
        return String(localized: "\(songs) songs · \(minutes) min")
    }

    static func savedAs(_ name: String) -> String {
        String(localized: "Saved as \(name)")
    }

    static var saveFailed: String {
        String(localized: "Couldn't save the playlist because the library database couldn't be written. Check free space and try again.")
    }

    /// What went wrong making a playlist, the cause and what to do next.
    static func failure(_ failure: PlaylistMakerFailure) -> String {
        switch failure {
        case .needsEntitlement:
            return String(localized: "Making playlists uses Flaccy's AI, which comes with Flaccy Lifetime.")
        case .emptyLibrary:
            return String(localized: "There is no music to choose from yet. Add your music, then ask again.")
        case .unreachable:
            return String(localized: "Couldn't make the playlist because Flaccy's AI couldn't be reached. Check your connection and try again.")
        case .quotaReached(let resetsAt):
            let time = resetsAt.formatted(date: .omitted, time: .shortened)
            return String(localized: "Couldn't make the playlist because today's AI allowance is used up. It comes back at \(time).")
        case .nothingFits(let note):
            return note.isEmpty ? String(localized: "Nothing in your library fits that. Try describing it another way.") : note
        case .declined:
            return String(localized: "That couldn't be made into a playlist. Describe the music you want to hear.")
        case .unavailable:
            return String(localized: "Couldn't make the playlist because Flaccy's AI is unavailable right now. Try again in a few minutes.")
        }
    }
}
