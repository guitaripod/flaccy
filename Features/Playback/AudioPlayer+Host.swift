import AVFoundation
import MidgarCore
import FlaccyCore

extension AudioPlayer: PlaybackEngineHost {

    var libraryRoot: URL { LibraryPaths.root }

    /// Single gating choke point for starting playback: every entry that begins
    /// audio (library taps, stations, radio, skips, queue jumps, remote commands)
    /// loads through the engine's loadTrack(at:), and the direct-resume branch of
    /// togglePlayPause re-checks before resuming an already-loaded item; both
    /// defer to the paywall once the trial has expired without a purchase.
    func isPlaybackGated() -> Bool {
        guard !PurchaseManager.shared.allowsPlayback else { return false }
        PurchaseManager.shared.requestPaywall()
        return true
    }

    func attachEqualizer(to item: AVPlayerItem) {
        EqualizerEngine.shared.attach(to: item)
    }

    /// A song on a server plays from its cached file once that is whole, and streams through the
    /// resource loader until then; either way the equalizer attaches to the item like any other.
    func remoteAsset(for track: Track) -> AVURLAsset {
        guard let song = track.remoteSong else { return AVURLAsset(url: track.fileURL) }
        let route = RemoteAssetRoute.route(for: song, completeFile: RemoteStreamCache.shared.completeFileURL(for: song))
        switch route {
        case .file(let url): return AVURLAsset(url: url)
        case .stream: return RemoteResourceLoader.shared.makeAsset(for: song)
        }
    }

    func activateAudioSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
    }

    func playFeedback(_ kind: PlaybackFeedbackKind) {
        feedback.play(kind)
    }

    func playbackStateDidUpdate() {
        updateNowPlayingInfo()
    }

    func trackDidStart(_ track: Track) {
        trackStartTime = Date()
        hasScrobbled = false
        ensureArtworkLoaded(for: track)
        sendNowPlayingToLastFM(track: track)
        reportRemoteStart(of: track)
        PurchaseManager.shared.noteTrackStarted(track)
    }

    func trackWillBeSkipped() {
        checkScrobbleOnSkip()
    }

    func trackDidFinishNaturally() {
        scrobbleAtNaturalEndIfEligible()
        recordReviewSuccessUnlessSample()
    }

    func playbackDidProgress() {
        checkScrobbleCriteria()
    }

    func artworkIsNeeded(for track: Track) {
        ensureArtworkLoaded(for: track)
    }

    /// Hydrates a restored record into a Track, resolving artwork once per
    /// album through the shared downsampled cache instead of decoding each
    /// track's embedded cover, so a restored queue never pins duplicate
    /// full-size images.
    func restoredTrack(from record: TrackRecord, artworkByAlbum: inout [String: PlatformImage?]) -> Track {
        let key = "\(record.albumTitle)|\(record.artist)"
        let artwork: PlatformImage?
        if let cached = artworkByAlbum[key] {
            artwork = cached
        } else {
            artwork = AlbumArtworkCache.shared.artwork(forAlbum: record.albumTitle, artist: record.artist)
            artworkByAlbum[key] = artwork
        }
        return Track.from(record: record, artwork: artwork)
    }

    func libraryTracks() -> [Track] {
        Library.shared.allTracks
    }
}
