import Foundation

/// The cheap facts about a file that decide whether it must be inspected again:
/// its byte size and its modification time in milliseconds since the Unix epoch.
public struct FileSignature: Equatable, Sendable {
    public let size: Int64
    public let modifiedMilliseconds: Int64

    public init(size: Int64, modifiedMilliseconds: Int64) {
        self.size = size
        self.modifiedMilliseconds = modifiedMilliseconds
    }
}

/// What a library remembers about a track's file between scans.
public struct StoredVersion: Equatable, Sendable {
    public var signature: FileSignature?
    public var fingerprint: String?
    public var revision: Int
    public var revisedAt: Date?

    public init(signature: FileSignature?, fingerprint: String?, revision: Int, revisedAt: Date?) {
        self.signature = signature
        self.fingerprint = fingerprint
        self.revision = revision
        self.revisedAt = revisedAt
    }
}

/// What a scan decides about a known path: the first fingerprint is a baseline,
/// a fingerprint that matches or cannot be read is a retag of the same audio,
/// and a different fingerprint is a new version of the song. Every client makes
/// these decisions here so a rescan files the same track the same way.
public enum TrackRevision {

    public enum Outcome: Equatable, Sendable {
        case unchanged
        case baseline
        case retagged
        case newVersion
    }

    public static let newMixWindow: TimeInterval = 14 * 86_400
    public static let previousVersionRetention: TimeInterval = 30 * 86_400

    /// A file whose size or modification time moved, or that was never signed, is read again.
    public static func needsInspection(stored: StoredVersion, current: FileSignature) -> Bool {
        stored.signature != current
    }

    public static func classify(stored: StoredVersion, currentFingerprint: String?) -> Outcome {
        guard let known = stored.fingerprint else { return .baseline }
        guard let current = currentFingerprint, current != known else { return .retagged }
        return .newVersion
    }

    /// Records the scan's outcome. Only a new version advances the revision and
    /// stamps `revisedAt`; a retag keeps the fingerprint it already had when the
    /// new one cannot be read.
    public static func applying(
        _ outcome: Outcome,
        to stored: StoredVersion,
        signature: FileSignature,
        fingerprint: String?,
        now: Date
    ) -> StoredVersion {
        switch outcome {
        case .unchanged:
            return stored
        case .baseline:
            return StoredVersion(
                signature: signature,
                fingerprint: fingerprint,
                revision: stored.revision,
                revisedAt: stored.revisedAt
            )
        case .retagged:
            return StoredVersion(
                signature: signature,
                fingerprint: fingerprint ?? stored.fingerprint,
                revision: stored.revision,
                revisedAt: stored.revisedAt
            )
        case .newVersion:
            return StoredVersion(
                signature: signature,
                fingerprint: fingerprint,
                revision: stored.revision + 1,
                revisedAt: now
            )
        }
    }

    /// Whether a track's new mix badge is still shown: strictly within the window after its revision.
    public static func showsNewMix(revisedAt: Date?, now: Date) -> Bool {
        guard let revisedAt else { return false }
        return now.timeIntervalSince(revisedAt) < newMixWindow
    }

    /// A replaced file's previous version is kept for the retention period, then may be dropped.
    public static func previousVersionExpired(movedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(movedAt) >= previousVersionRetention
    }

    /// The identity stored for a file: `flac:` plus the STREAMINFO MD5 when the
    /// file carries one, otherwise `sha256:` plus the hash of its audio payload.
    public static func fingerprint(of location: AudioPayload.Location, sha256Hex: String?) -> String? {
        switch location {
        case .flacMD5(let digest):
            return "flac:" + digest
        case .ranges:
            return sha256Hex.map { "sha256:" + $0 }
        }
    }
}
