import Combine
import Foundation

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

final class NowPlayingViewModel {

    struct State {
        let title: String
        let artist: String
        let albumTitle: String
        let artistAlbum: String
        let artwork: PlatformImage?
        let isPlaying: Bool
        let currentTime: TimeInterval
        let duration: TimeInterval
        let currentTimeFormatted: String
        let remainingTimeFormatted: String
    }

    private let audioPlayer: AudioPlaying
    private var loadingArtworkKey: String?

    let statePublisher = PassthroughSubject<State, Never>()

    init(audioPlayer: AudioPlaying = AudioPlayer.shared) {
        self.audioPlayer = audioPlayer

        NotificationCenter.default.addObserver(
            self, selector: #selector(stateChanged), name: AudioPlayer.trackDidChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(stateChanged), name: AudioPlayer.playbackStateDidChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(stateChanged), name: AudioPlayer.playbackProgressDidChange, object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    var currentState: State { buildState() }

    func togglePlayPause() {
        audioPlayer.togglePlayPause()
    }

    func nextTrack() {
        audioPlayer.nextTrack()
    }

    func previousTrack() {
        audioPlayer.previousTrack()
    }

    func seek(to time: TimeInterval) {
        audioPlayer.seek(to: time)
    }

    private func buildState() -> State {
        let track = audioPlayer.currentTrack
        let current = audioPlayer.currentTime
        let total = audioPlayer.duration
        let remaining = max(0, total - current)

        var artwork: PlatformImage?
        if let track {
            let full = track.artwork
                ?? AlbumArtworkCache.shared.artwork(forAlbum: track.albumTitle, artist: track.artist)
            artwork = full
                ?? AlbumArtworkCache.shared.thumbnail(forAlbum: track.albumTitle, artist: track.artist)

            if full == nil {
                let key = "\(track.albumTitle)\0\(track.artist)"
                if loadingArtworkKey != key {
                    loadingArtworkKey = key
                    AlbumArtworkCache.shared.loadArtwork(forAlbum: track.albumTitle, artist: track.artist) { [weak self] _ in
                        self?.loadingArtworkKey = nil
                        self?.stateChanged()
                    }
                }
            }
        }

        return State(
            title: track?.title ?? "",
            artist: track?.artist ?? "",
            albumTitle: track?.albumTitle ?? "",
            artistAlbum: [track?.artist, track?.albumTitle]
                .compactMap { $0 }
                .joined(separator: " — "),
            artwork: artwork,
            isPlaying: audioPlayer.isPlaying,
            currentTime: current,
            duration: total,
            currentTimeFormatted: formatTime(current),
            remainingTimeFormatted: "-\(formatTime(remaining))"
        )
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let total = Int(time)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    @objc private func stateChanged() {
        statePublisher.send(buildState())
    }
}
