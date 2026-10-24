import FlaccyCore
import Foundation

/// The words a lyrics view shows when there is no lyric to show, shared by iOS
/// and macOS so both say exactly what happened. The Linux client carries the
/// same text in `linux/shared/src/lyrics/status.rs`.
nonisolated enum LyricsStatusCopy {

    struct Words {
        let title: String
        let body: String
    }

    static var idle: Words {
        Words(
            title: String(localized: "Nothing Playing"),
            body: String(localized: "Play a song and its lyrics show up here.")
        )
    }

    static var searching: Words {
        Words(
            title: String(localized: "Looking Up Lyrics…"),
            body: String(localized: "Checking the song's tags, files next to it, and lrclib.net.")
        )
    }

    static func missing(song: String) -> Words {
        Words(
            title: String(localized: "No Lyrics for “\(song)”"),
            body: String(localized: "Flaccy checked the file's own tags, looked for a .lrc or .elrc file next to the song, and asked lrclib.net. None of them have words for it. lrclib is written by its community, so Flaccy asks again in 30 days. A .lrc file saved next to the song shows up straight away.")
        )
    }

    static var instrumental: Words {
        Words(
            title: String(localized: "Instrumental"),
            body: String(localized: "lrclib.net lists this track as an instrumental, so there are no words to follow.")
        )
    }

    static func failed(_ failure: LyricsFailure) -> Words {
        switch failure {
        case .unreachable:
            return Words(
                title: String(localized: "Can't Reach lrclib.net"),
                body: String(localized: "Flaccy couldn't open a connection. Check that you're online; lyrics load as soon as you are.")
            )
        case .timedOut:
            return Words(
                title: String(localized: "lrclib.net Took Too Long"),
                body: String(localized: "The connection works, but the lyrics server didn't answer within 10 seconds. Try again in a moment.")
            )
        case .busy:
            return Words(
                title: String(localized: "lrclib.net Is Busy"),
                body: String(localized: "The lyrics server asked Flaccy to slow down and still hadn't room after a retry. Give it a minute and try again.")
            )
        case .server(let code):
            return Words(
                title: String(localized: "lrclib.net Is Having Trouble"),
                body: String(localized: "The lyrics server answered with an error (HTTP \(code)). These usually clear up within a few minutes.")
            )
        case .rejected(let code):
            return Words(
                title: String(localized: "lrclib.net Turned the Request Down"),
                body: String(localized: "The lyrics server answered HTTP \(code) instead of lyrics. Trying again is harmless, but this one may need an update to Flaccy.")
            )
        }
    }
}
