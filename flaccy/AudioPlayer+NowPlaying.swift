import Foundation
import MediaPlayer

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

extension AudioPlayer {

    func artworkCacheKey(for track: Track) -> String {
        "\(track.albumTitle)\u{0}\(track.artist)"
    }

    /// Media-panel-sized art preferred, thumbnail as a stopgap so system Now
    /// Playing never has to wait for a large decode or sit empty after eviction.
    func resolveArtwork(for track: Track) -> PlatformImage? {
        track.artwork
            ?? AlbumArtworkCache.shared.nowPlayingArtwork(forAlbum: track.albumTitle, artist: track.artist)
            ?? AlbumArtworkCache.shared.thumbnail(forAlbum: track.albumTitle, artist: track.artist)
    }

    func ensureArtworkLoaded(for track: Track) {
        let key = artworkCacheKey(for: track)
        if nowPlayingArtworkKey != key {
            nowPlayingArtworkKey = key
            nowPlayingArtworkImage = nil
        }
        if let resolved = resolveArtwork(for: track) {
            nowPlayingArtworkImage = resolved
        }
        if AlbumArtworkCache.shared.nowPlayingArtwork(forAlbum: track.albumTitle, artist: track.artist) == nil {
            AlbumArtworkCache.shared.loadNowPlayingArtwork(forAlbum: track.albumTitle, artist: track.artist) { [weak self] image in
                guard let self else { return }
                if let image, self.nowPlayingArtworkKey == key {
                    self.nowPlayingArtworkImage = image
                }
                self.updateNowPlayingInfo()
            }
        }
        if nowPlayingArtworkImage == nil {
            AlbumArtworkCache.shared.loadThumbnail(forAlbum: track.albumTitle, artist: track.artist) { [weak self] image in
                guard let self else { return }
                if let image, self.nowPlayingArtworkKey == key, self.nowPlayingArtworkImage == nil {
                    self.nowPlayingArtworkImage = image
                    self.updateNowPlayingInfo()
                }
            }
        }
    }

    func mediaItemArtwork(from image: PlatformImage) -> MPMediaItemArtwork {
        let bounds: CGSize
        #if canImport(UIKit)
        bounds = image.size.width > 0 && image.size.height > 0
            ? image.size
            : CGSize(width: 600, height: 600)
        #else
        bounds = image.size.width > 0 && image.size.height > 0
            ? image.size
            : NSSize(width: 600, height: 600)
        #endif
        return MPMediaItemArtwork(boundsSize: bounds) { @Sendable _ in image }
    }

    /// The system playbackState is derived here — the one sink every state
    /// transition already flows through — so paths that mutate `isPlaying`
    /// directly (loadTrack, auto-advance, queue exhaustion) can never leave
    /// the lock-screen / menu-bar Now Playing widget stale.
    func updateNowPlayingInfo() {
        let center = MPNowPlayingInfoCenter.default()
        center.playbackState = isPlaying ? .playing : .paused

        guard let track = currentTrack else {
            nowPlayingArtworkImage = nil
            nowPlayingArtworkKey = nil
            center.nowPlayingInfo = nil
            syncRemoteCommandState()
            return
        }

        let key = artworkCacheKey(for: track)
        if nowPlayingArtworkKey != key {
            nowPlayingArtworkKey = key
            nowPlayingArtworkImage = nil
        }
        if let resolved = resolveArtwork(for: track) {
            nowPlayingArtworkImage = resolved
        }

        let reportedDuration = duration > 0 ? duration : track.duration
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.albumTitle,
            MPMediaItemPropertyPlaybackDuration: reportedDuration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyPlaybackQueueIndex: currentIndex,
            MPNowPlayingInfoPropertyPlaybackQueueCount: queue.count,
            MPMediaItemPropertyAlbumTrackNumber: track.trackNumber,
        ]

        if let image = nowPlayingArtworkImage {
            info[MPMediaItemPropertyArtwork] = mediaItemArtwork(from: image)
        } else if let existing = center.nowPlayingInfo?[MPMediaItemPropertyArtwork] {
            // Keep whatever the system already has rather than blanking art on
            // a progress/pause refresh that lost the cache entry mid-flight.
            info[MPMediaItemPropertyArtwork] = existing
        }

        center.nowPlayingInfo = info
        syncRemoteCommandState()
    }
}
