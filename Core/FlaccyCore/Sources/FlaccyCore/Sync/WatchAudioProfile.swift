import Foundation

/// Whether an audio file is already small enough to ship untouched.
public enum AudioSourceKind: Sendable, Equatable {
    case lossless
    case lossy
    case unknown
}

/// How faithfully a track is encoded for the wrist. The watch plays through
/// Bluetooth, which is lossy end to end, so the lossless original buys
/// nothing there while costing three to eight times the bytes.
public enum WatchAudioProfile: String, CaseIterable, Codable, Sendable {
    case original
    case high
    case balanced
    case compact

    public static let standard: WatchAudioProfile = .high

    /// Target AAC-LC bit rate in bits per second; `nil` ships files untouched.
    public var bitRate: Int? {
        switch self {
        case .original: nil
        case .high: 256_000
        case .balanced: 192_000
        case .compact: 128_000
        }
    }

    public var transcodes: Bool { bitRate != nil }

    /// Room for the tags and the small embedded cover an encoded file carries.
    static let containerAllowanceBytes: Int64 = 40_000

    /// Whether `kind` has to be encoded under this profile. Lossy sources
    /// always pass through: re-encoding them loses quality for no real saving.
    public func requiresEncoding(for kind: AudioSourceKind) -> Bool {
        transcodes && kind != .lossy
    }

    /// Estimated size on the watch, never more than the source itself.
    public func estimatedBytes(
        durationSeconds: TimeInterval,
        sourceBytes: Int64,
        sourceKind: AudioSourceKind
    ) -> Int64 {
        guard let bitRate, requiresEncoding(for: sourceKind), durationSeconds > 0 else { return sourceBytes }
        let payload = Int64((durationSeconds * Double(bitRate) / 8).rounded(.up))
        return min(sourceBytes, payload + Self.containerAllowanceBytes)
    }
}
