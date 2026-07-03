import Foundation

/// Keys shared by the iOS sender and the watch receiver for WatchConnectivity payloads.
public enum SyncKeys {
    /// File-transfer metadata describing where the track belongs on the watch.
    public static let relativePath = "relativePath"
    public static let title = "title"
    public static let artist = "artist"
    public static let album = "album"
    public static let trackNumber = "trackNumber"
    public static let duration = "duration"

    /// Heartbeat (watch -> phone, via updateApplicationContext): the watch's
    /// authoritative state. The phone mirrors this exactly — it never infers
    /// "on watch" from its own transfer-finished callbacks.
    public static let syncedPaths = "syncedPaths"
    public static let freeBytes = "freeBytes"
    public static let isFull = "isFull"
    public static let lastErrorPath = "lastErrorPath"
    public static let lastErrorReason = "lastErrorReason"

    /// User-info command (phone -> watch).
    public static let command = "command"
    public static let removePaths = "removePaths"
    public static let commandRemove = "remove"
    public static let commandRemoveAll = "removeAll"
    public static let commandGetState = "getState"
}

/// Reason a track failed to persist on the watch.
public enum StoreFailureReason: String, Sendable {
    case diskFull
    case writeFailed
    case sourceMissing
}

/// Canonicalizes a relative path so the phone and watch always compare equal.
/// APFS is normalization-insensitive (NFC/NFD map to the same file) but Swift
/// `String`/`Set` comparison is byte-wise, so a directory read-back can differ
/// from the written form and break matching. Normalize to NFC everywhere.
public func canonicalSyncPath(_ path: String) -> String {
    path.precomposedStringWithCanonicalMapping
}

/// Typed wrapper around the plist dictionary carried in `transferFile(_:metadata:)`.
public struct TransferMetadata: Sendable, Equatable {
    public let relativePath: String
    public let title: String
    public let artist: String
    public let album: String
    public let trackNumber: Int
    public let duration: TimeInterval

    public init(
        relativePath: String,
        title: String,
        artist: String,
        album: String,
        trackNumber: Int,
        duration: TimeInterval
    ) {
        self.relativePath = canonicalSyncPath(relativePath)
        self.title = title
        self.artist = artist
        self.album = album
        self.trackNumber = trackNumber
        self.duration = duration
    }

    public var dictionary: [String: Any] {
        [
            SyncKeys.relativePath: relativePath,
            SyncKeys.title: title,
            SyncKeys.artist: artist,
            SyncKeys.album: album,
            SyncKeys.trackNumber: trackNumber,
            SyncKeys.duration: duration,
        ]
    }

    public init?(dictionary: [String: Any]?) {
        guard
            let dictionary,
            let relativePath = dictionary[SyncKeys.relativePath] as? String,
            !relativePath.isEmpty
        else { return nil }
        self.relativePath = canonicalSyncPath(relativePath)
        self.title = dictionary[SyncKeys.title] as? String ?? ""
        self.artist = dictionary[SyncKeys.artist] as? String ?? ""
        self.album = dictionary[SyncKeys.album] as? String ?? ""
        self.trackNumber = dictionary[SyncKeys.trackNumber] as? Int ?? 0
        self.duration = dictionary[SyncKeys.duration] as? TimeInterval ?? 0
    }
}
