import Foundation

/// What a queue was started from, so Home can name it: an album, a playlist,
/// a suggested mix, a radio, or a queue of anything else. `id` is the
/// client's own identifier for the thing (album key, playlist id, mix id).
public struct PlaybackContext: Codable, Equatable, Hashable, Sendable {

    public enum Kind: String, Codable, Sendable {
        case album
        case playlist
        case mix
        case radio
        case queue
    }

    public var kind: Kind
    public var id: String
    public var title: String
    public var subtitle: String

    public init(kind: Kind, id: String, title: String, subtitle: String) {
        self.kind = kind
        self.id = id
        self.title = title
        self.subtitle = subtitle
    }

    /// Unique across kinds, so an album and a playlist with the same name
    /// never collide in Jump Back In.
    public var key: String {
        "\(kind.rawValue):\(id)"
    }

    /// One entry of a queue as far as naming its context goes.
    public struct QueueEntry: Equatable, Sendable {
        public var album: String
        public var credit: String

        public init(album: String, credit: String) {
            self.album = album
            self.credit = credit
        }
    }

    /// An album when every entry shares one album title and credit (compared
    /// case-insensitively, ignoring surrounding space), otherwise a plain
    /// queue with no title for the client to name.
    public static func derived(from queue: [QueueEntry]) -> PlaybackContext {
        guard let first = queue.first, !HomeKeys.fold(first.album).isEmpty else { return .anonymousQueue }
        let albumKey = HomeKeys.album(title: first.album, credit: first.credit)
        guard queue.allSatisfy({ HomeKeys.album(title: $0.album, credit: $0.credit) == albumKey }) else {
            return .anonymousQueue
        }
        return PlaybackContext(kind: .album, id: albumKey, title: first.album, subtitle: first.credit)
    }

    public static let anonymousQueue = PlaybackContext(kind: .queue, id: "", title: "", subtitle: "")
}

/// The one normalization Home uses for album identity, so a context recorded
/// at play time and an album found in the history agree.
public enum HomeKeys {
    public static let separator = "\u{1F}"

    public static func fold(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public static func album(title: String, credit: String) -> String {
        fold(title) + separator + fold(credit)
    }
}
