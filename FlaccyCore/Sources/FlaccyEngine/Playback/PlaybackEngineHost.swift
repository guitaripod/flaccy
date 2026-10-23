import AVFoundation
import Foundation

public enum PlaybackFeedbackKind: Sendable {
    case light
    case medium
    case selection
}

/// Everything a continuation build needs, snapshotted on the main actor before
/// the work moves off it.
public struct ContinuationRequest: Sendable {
    public let pool: [Track]
    public let queued: [Track]
    public let existing: Set<URL>
    public let seedArtist: String?
    public let seedTrack: Track?

    public init(pool: [Track], queued: [Track], existing: Set<URL>, seedArtist: String?, seedTrack: Track?) {
        self.pool = pool
        self.queued = queued
        self.existing = existing
        self.seedArtist = seedArtist
        self.seedTrack = seedTrack
    }
}

public typealias ContinuationBuilder = @Sendable (ContinuationRequest) async -> [Track]

/// What the app supplies to the engine: the trial gate, the equalizer tap, the
/// audio session, haptics, Now Playing and scrobbling hooks, and the library
/// facts the engine cannot know (root folder, artwork, track pool).
@MainActor
public protocol PlaybackEngineHost: AnyObject {
    var libraryRoot: URL { get }
    func isPlaybackGated() -> Bool
    func attachEqualizer(to item: AVPlayerItem)
    func activateAudioSession()
    func playFeedback(_ kind: PlaybackFeedbackKind)
    func playbackStateDidUpdate()
    func trackDidStart(_ track: Track)
    func trackWillBeSkipped()
    func trackDidFinishNaturally()
    func playbackDidProgress()
    func artworkIsNeeded(for track: Track)
    func restoredTrack(from record: TrackRecord, artworkByAlbum: inout [String: PlatformImage?]) -> Track
    func libraryTracks() -> [Track]
}
