import FlaccyCore
import Foundation
import os

/// What music weighs on the watch under a given quality, answered without
/// touching the sync service's own profile so every candidate quality can be
/// priced side by side. The source-size lookup is a seam: it reads the file
/// system by default and the screenshot demo swaps in believable figures for
/// its tiny fictional files.
nonisolated enum WatchSyncSizing {

    /// Replaced once at launch by the screenshot demo, before any sync reads it.
    nonisolated(unsafe) static var sourceBytes: @Sendable (Track) -> Int64 = { diskBytes(of: $0.fileURL) }

    private static let diskSizes = OSAllocatedUnfairLock(initialState: [String: Int64]())

    /// Forgets every cached file size, for when the library's files may have changed.
    static func invalidate() {
        diskSizes.withLock { $0.removeAll() }
    }

    static func estimatedBytes(for track: Track, profile: WatchAudioProfile) -> Int64 {
        profile.estimatedBytes(
            durationSeconds: track.duration,
            sourceBytes: sourceBytes(track),
            sourceKind: SyncStem.kind(ofExtension: track.fileURL.pathExtension)
        )
    }

    static func totalBytes(in album: Album, profile: WatchAudioProfile) -> Int64 {
        album.tracks.reduce(0) { $0 + estimatedBytes(for: $1, profile: profile) }
    }

    /// The whole library priced once per quality, in a single pass over the tracks.
    static func libraryBytes(tracks: [Track]) -> [WatchAudioProfile: Int64] {
        var totals: [WatchAudioProfile: Int64] = [:]
        for track in tracks {
            let source = sourceBytes(track)
            let kind = SyncStem.kind(ofExtension: track.fileURL.pathExtension)
            for profile in WatchAudioProfile.allCases {
                totals[profile, default: 0] += profile.estimatedBytes(
                    durationSeconds: track.duration,
                    sourceBytes: source,
                    sourceKind: kind
                )
            }
        }
        return totals
    }

    private static func diskBytes(of url: URL) -> Int64 {
        let key = url.path
        if let cached = diskSizes.withLock({ $0[key] }) { return cached }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        diskSizes.withLock { $0[key] = size }
        return size
    }
}

/// Whether a watch is paired with the app installed. Real sessions answer from
/// WatchConnectivity; the screenshot demo substitutes a paired, ready watch.
struct WatchSyncLink: Equatable {

    var isSupported: Bool
    var isPaired: Bool
    var isInstalled: Bool
    var isActivated = true
    var hasAnswered = true
    var isReachable = true

    static var simulated: WatchSyncLink?

    static var isSimulated: Bool { simulated != nil }

    var isReady: Bool { isSupported && isPaired && isInstalled }

    static func current(for service: WatchSyncService) -> WatchSyncLink {
        simulated ?? WatchSyncLink(
            isSupported: service.isSupported,
            isPaired: service.isPaired,
            isInstalled: service.isWatchAppInstalled,
            isActivated: service.isActivated,
            hasAnswered: service.hasWatchAnswered,
            isReachable: service.isReachable
        )
    }
}
