import Foundation

/// Why lrclib could not be asked, or did not answer usefully. Each case is a
/// different thing for a listener to do, so each gets its own words. Mirrored
/// in Rust as `linux/shared/src/lyrics/status.rs`.
public enum LyricsFailure: Sendable, Equatable {
    case unreachable
    case timedOut
    case busy
    case server(Int)
    case rejected(Int)

    /// What an HTTP status other than success and 404 means for the lookup.
    public static func forStatus(_ code: Int) -> LyricsFailure {
        switch code {
        case 429: return .busy
        case 500...599: return .server(code)
        default: return .rejected(code)
        }
    }
}
