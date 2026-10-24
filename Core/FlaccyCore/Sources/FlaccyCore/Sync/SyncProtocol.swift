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
    public static let bytes = "bytes"

    /// Heartbeat (watch -> phone, via updateApplicationContext): the watch's
    /// authoritative state. The phone mirrors this exactly — it never infers
    /// "on watch" from its own transfer-finished callbacks.
    public static let syncedPaths = "syncedPaths"
    public static let freeBytes = "freeBytes"
    public static let isFull = "isFull"
    public static let lastErrorPath = "lastErrorPath"
    public static let lastErrorReason = "lastErrorReason"
    public static let usedBytes = "usedBytes"
    public static let totalBytes = "totalBytes"

    /// The phone's enrichment job (phone -> watch, via updateApplicationContext).
    /// The watch renders what the phone is doing and never fetches metadata
    /// itself, so this is the only enrichment state that exists on the wrist.
    public static let enrichmentJob = "enrichmentJob"

    /// The run the phone is sending (phone -> watch, via updateApplicationContext).
    public static let syncBatch = "syncBatch"

    /// User-info command (phone -> watch).
    public static let command = "command"
    public static let removePaths = "removePaths"
    public static let commandRemove = "remove"
    public static let commandRemoveAll = "removeAll"
    public static let commandGetState = "getState"

    /// User-info commands (watch -> phone): the person deleted these on the
    /// watch (paths in `removePaths`), or played tracks there (`plays`, an
    /// array of `WatchPlayEntry` dictionaries).
    public static let commandRemoved = "removed"
    public static let commandPlays = "plays"
    public static let plays = "plays"
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
    public let bytes: Int64

    public init(
        relativePath: String,
        title: String,
        artist: String,
        album: String,
        trackNumber: Int,
        duration: TimeInterval,
        bytes: Int64 = 0
    ) {
        self.relativePath = canonicalSyncPath(relativePath)
        self.title = title
        self.artist = artist
        self.album = album
        self.trackNumber = trackNumber
        self.duration = duration
        self.bytes = bytes
    }

    public var dictionary: [String: Any] {
        [
            SyncKeys.relativePath: relativePath,
            SyncKeys.title: title,
            SyncKeys.artist: artist,
            SyncKeys.album: album,
            SyncKeys.trackNumber: trackNumber,
            SyncKeys.duration: duration,
            SyncKeys.bytes: bytes,
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
        self.bytes = Self.byteCount(dictionary[SyncKeys.bytes])
    }

    /// A byte count survives a plist round trip as whichever integer width
    /// the other side happened to use, so every width is accepted.
    private static func byteCount(_ value: Any?) -> Int64 {
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? NSNumber { return value.int64Value }
        return 0
    }
}

/// Typed wrapper around the enrichment job the phone puts in its application
/// context. `EnrichmentJobProgress` is `Codable` but not a property-list type
/// and WatchConnectivity carries plist values only, so the wire form is one JSON
/// blob of the shared model itself — never a hand-copied dictionary, which is
/// how a fraction or a stale field would sneak onto the wrist.
public enum EnrichmentJobTransfer {

    public static func encode(_ progress: EnrichmentJobProgress) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(progress)
    }

    /// Decodes a context value, tolerating both an absent key (the phone has
    /// nothing to say) and a payload written by an older build.
    public static func decode(_ value: Any?) -> EnrichmentJobProgress? {
        guard let data = value as? Data else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(EnrichmentJobProgress.self, from: data)
    }
}
