import Foundation
import FlaccyCore

/// The words only the Mac's Home says, beside the shared `HomeCopy`.
enum MacHomeCopy {

    static var goToAlbum: String { String(localized: "Go to Album") }
    static var goToPlaylist: String { String(localized: "Go to Playlist") }
    static var playFromBeginning: String { String(localized: "Play from the Beginning") }
    static var removeFromJumpBackIn: String { String(localized: "Remove from Jump Back In") }
    static var playNext: String { String(localized: "Play Next") }
    static var addToQueue: String { String(localized: "Add to Queue") }
    static var saveAsPlaylist: String { String(localized: "Save as Playlist…") }

    static func albumLine(artist: String) -> String {
        String(localized: "Album · \(artist)")
    }

    static func playlistLine(count: Int) -> String {
        String(localized: "Playlist · \(HomeCopy.songCount(count))")
    }

    static func mixLine(count: Int) -> String {
        String(localized: "Mix · \(HomeCopy.songCount(count))")
    }

    static func radioLine() -> String {
        String(localized: "Radio")
    }

    /// The second line of a Jump Back In row: what kind of thing it is, and
    /// its artist or size.
    static func subtitle(for item: HomeFeed.Item) -> String {
        switch item.context.kind {
        case .album: albumLine(artist: item.context.subtitle)
        case .playlist: playlistLine(count: item.trackCount)
        case .mix: mixLine(count: item.trackCount)
        case .radio, .queue: radioLine()
        }
    }
}
