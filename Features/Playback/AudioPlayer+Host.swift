import AVFoundation
import MidgarCore
import FlaccyCore
#if os(iOS)
import UIKit
#endif

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

    func attachEqualizer(to item: AVPlayerItem, for track: Track) {
        let store = SongVolumeStore.shared
        EqualizerEngine.shared.attach(to: item, songKey: store.key(for: track), songGain: store.level(for: track))
    }

    /// A song on a server plays from its cached file once that is whole, and streams through the
    /// resource loader until then; either way the equalizer attaches to the item like any other.
    func remoteAsset(for track: Track) -> AVURLAsset {
        guard let song = track.remoteSong else { return AVURLAsset(url: track.fileURL) }
        let route = RemoteAssetRoute.route(for: song, completeFile: RemoteStreamCache.shared.completeFileURL(for: song))
        switch route {
        case .file(let url): return AVURLAsset(url: url, options: RemoteAudioType.assetOptions(forSuffix: url.pathExtension))
        case .stream: return RemoteResourceLoader.shared.makeAsset(for: song)
        }
    }

    @discardableResult
    func activateAudioSession() -> Bool {
        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            return true
        } catch {
            MidgarLog.notice("Audio session refused: \(error.localizedDescription)", category: .playback)
            return false
        }
        #else
        return true
        #endif
    }

    var interruptionResume: InterruptionResume {
        get { InterruptionResume.stored }
        set {
            InterruptionResume.stored = newValue
            MidgarLog.info("Resume after another app set to \(newValue.rawValue)", category: .playback)
            #if os(iOS)
            InterruptionResumeWatcher.shared.choiceChanged()
            #endif
        }
    }

    func interruptionDidBegin() {
        #if os(iOS)
        InterruptionResumeWatcher.shared.interruptionBegan(in: engine)
        #endif
    }

    func playFeedback(_ kind: PlaybackFeedbackKind) {
        feedback.play(kind)
    }

    func playbackStateDidUpdate() {
        updateNowPlayingInfo()
        keepQueueWhenStoppedInBackground()
    }

    /// A session Siri, a shortcut or the lock screen ran entirely in the background never resigns active, the one
    /// moment the queue used to be kept, so it is also kept when the music stops there: the point after which iOS may
    /// close the app and Resume would otherwise find nothing.
    private func keepQueueWhenStoppedInBackground() {
        #if os(iOS)
        guard !isPlaying, UIApplication.shared.applicationState == .background else { return }
        engine.saveQueueState()
        #endif
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
        reportMusicPlayingIfSecondLookWaits()
    }

    /// A waiting second look starts on music that is really playing: time has
    /// moved on the track. A queue restored at launch sits paused, and a file
    /// that is missing or on a drive that is not connected never moves, so
    /// neither spends the free days.
    private func reportMusicPlayingIfSecondLookWaits() {
        guard PurchaseManager.shared.state == .secondLookReady, isPlaying, currentTime > 0,
              let track = currentTrack
        else { return }
        PurchaseManager.shared.noteOwnMusicPlaying(track)
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
