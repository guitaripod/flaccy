import Foundation

/// One play the watch performed on its own, reported to the phone so it can
/// be scrobbled and counted. The id makes redelivery harmless.
public struct WatchPlayEntry: Sendable, Equatable {
    public let id: String
    public let path: String
    public let title: String
    public let artist: String
    public let album: String
    public let startedAt: Date
    public let durationSeconds: Int

    public init(
        id: String = UUID().uuidString,
        path: String,
        title: String,
        artist: String,
        album: String,
        startedAt: Date,
        durationSeconds: Int
    ) {
        self.id = id
        self.path = canonicalSyncPath(path)
        self.title = title
        self.artist = artist
        self.album = album
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
    }

    public var dictionary: [String: Any] {
        [
            Key.id: id,
            Key.path: path,
            Key.title: title,
            Key.artist: artist,
            Key.album: album,
            Key.startedAt: startedAt.timeIntervalSince1970,
            Key.durationSeconds: durationSeconds,
        ]
    }

    public init?(dictionary: [String: Any]?) {
        guard
            let dictionary,
            let id = dictionary[Key.id] as? String, !id.isEmpty,
            let path = dictionary[Key.path] as? String, !path.isEmpty,
            let started = (dictionary[Key.startedAt] as? NSNumber)?.doubleValue
        else { return nil }
        self.init(
            id: id,
            path: path,
            title: dictionary[Key.title] as? String ?? "",
            artist: dictionary[Key.artist] as? String ?? "",
            album: dictionary[Key.album] as? String ?? "",
            startedAt: Date(timeIntervalSince1970: started),
            durationSeconds: (dictionary[Key.durationSeconds] as? NSNumber)?.intValue ?? 0
        )
    }

    private enum Key {
        static let id = "id"
        static let path = "path"
        static let title = "title"
        static let artist = "artist"
        static let album = "album"
        static let startedAt = "startedAt"
        static let durationSeconds = "durationSeconds"
    }
}

/// When a play on the watch counts.
public enum WatchPlayRule {

    /// Mirrors `meetsScrobbleCriteria` and its callers in
    /// `Features/Playback/AudioPlayer.swift`: a track with a known duration counts once
    /// `min(240, max(30, duration / 2))` seconds have been played, so tracks
    /// shorter than 30 seconds never qualify.
    public static func qualifies(playedSeconds: TimeInterval, trackDuration: TimeInterval) -> Bool {
        guard trackDuration > 0 else { return false }
        return playedSeconds >= min(240, max(30, trackDuration / 2))
    }
}

/// Remembers which watch plays the phone has already taken, so a delivery the
/// transport repeats cannot count a play twice.
public struct WatchPlayLedger: Sendable, Equatable {

    public static let capacity = 2_000

    public private(set) var seenIDs: [String]
    private var seen: Set<String>

    public init(seenIDs: [String] = []) {
        var ordered: [String] = []
        var members = Set<String>()
        for id in seenIDs where members.insert(id).inserted { ordered.append(id) }
        let kept = Array(ordered.suffix(Self.capacity))
        self.seenIDs = kept
        self.seen = Set(kept)
    }

    /// The entries not seen before, in the order given; each is remembered.
    public mutating func accept(_ entries: [WatchPlayEntry]) -> [WatchPlayEntry] {
        var fresh: [WatchPlayEntry] = []
        for entry in entries where !seen.contains(entry.id) {
            seen.insert(entry.id)
            seenIDs.append(entry.id)
            fresh.append(entry)
        }
        trimToCapacity()
        return fresh
    }

    private mutating func trimToCapacity() {
        guard seenIDs.count > Self.capacity else { return }
        let dropped = seenIDs.prefix(seenIDs.count - Self.capacity)
        seenIDs.removeFirst(dropped.count)
        seen.subtract(dropped)
    }
}
